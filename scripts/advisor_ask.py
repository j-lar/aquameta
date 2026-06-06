#!/usr/bin/env python3
"""
Aquameta Advisor — invoke the pre-loaded advisory corpus via Claude API.

Usage:
    python scripts/advisor_ask.py "Is this approach correct?"
    echo "question" | python scripts/advisor_ask.py

The advisor name defaults to 'aquameta'. Override with --advisor <name>.
The model is read from advisor.advisor.model — update that row to switch models.
Every invocation is recorded in advisor.invocation.
"""

import sys
import os
import argparse
import psycopg2
import anthropic

DB_DSN = "host=localhost port=5432 dbname=aquameta user=aquameta password=aquameta client_encoding=utf8"


def get_question(args_question):
    if args_question:
        return " ".join(args_question)
    if not sys.stdin.isatty():
        return sys.stdin.read().strip()
    print("Question: ", end="", flush=True)
    return input().strip()


def load_advisor(cur, name):
    cur.execute(
        "SELECT id, model, system_prompt FROM advisor.advisor WHERE name = %s",
        (name,)
    )
    row = cur.fetchone()
    if not row:
        raise ValueError(f"No advisor named '{name}'. Check advisor.advisor table.")
    return {"id": row[0], "model": row[1], "system_prompt": row[2]}


def load_context(cur, advisor_id):
    cur.execute(
        """
        SELECT title, body
        FROM advisor.context_document
        WHERE advisor_id = %s
        ORDER BY sort_order ASC
        """,
        (advisor_id,)
    )
    docs = cur.fetchall()
    parts = []
    for title, body in docs:
        parts.append(f"## {title}\n\n{body.strip()}")
    return "\n\n---\n\n".join(parts)


def record_invocation(cur, advisor_id, question, context_snapshot, response, model, usage):
    cur.execute(
        """
        INSERT INTO advisor.invocation
            (advisor_id, question, context_snapshot, response, model_used, input_tokens, output_tokens)
        VALUES (%s, %s, %s, %s, %s, %s, %s)
        RETURNING id
        """,
        (
            advisor_id,
            question,
            context_snapshot,
            response,
            model,
            usage.input_tokens if usage else None,
            usage.output_tokens if usage else None,
        )
    )
    return cur.fetchone()[0]


def main():
    parser = argparse.ArgumentParser(description="Ask the Aquameta advisor")
    parser.add_argument("question", nargs="*", help="Question to ask")
    parser.add_argument("--advisor", default="aquameta", help="Advisor name (default: aquameta)")
    parser.add_argument("--no-record", action="store_true", help="Do not record invocation to DB")
    args = parser.parse_args()

    question = get_question(args.question)
    if not question:
        print("Error: no question provided.", file=sys.stderr)
        sys.exit(1)

    conn = psycopg2.connect(DB_DSN)
    cur = conn.cursor()

    advisor = load_advisor(cur, args.advisor)
    context = load_context(cur, advisor["id"])

    client = anthropic.Anthropic()

    user_message = f"""<context>
{context}
</context>

{question}"""

    print(f"[advisor:{args.advisor}] [{advisor['model']}] asking...\n", file=sys.stderr)

    message = client.messages.create(
        model=advisor["model"],
        max_tokens=4096,
        system=advisor["system_prompt"],
        messages=[{"role": "user", "content": user_message}],
    )

    response_text = message.content[0].text

    if not args.no_record:
        inv_id = record_invocation(
            cur,
            advisor["id"],
            question,
            context,
            response_text,
            advisor["model"],
            message.usage,
        )
        conn.commit()
        print(f"[recorded: advisor.invocation {inv_id}]\n", file=sys.stderr)

    conn.close()
    print(response_text)


if __name__ == "__main__":
    main()
