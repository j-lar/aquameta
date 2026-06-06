-- Magic Eight Ball widget + resource + bundle

-- 1. Widget
INSERT INTO widget.widget (name, html, css, post_js) VALUES (
'magic8ball',

$HTML$
<div id="{{= id }}" class="{{= name }}">
  <div class="ball">
    <div class="face front">
      <span class="eight">8</span>
    </div>
    <div class="face window">
      <div class="inner-circle">
        <div class="triangle">
          <span class="answer"></span>
        </div>
      </div>
    </div>
  </div>
  <p class="prompt">Ask a question, then click the ball.</p>
</div>
$HTML$,

$CSS$
.magic8ball {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  min-height: 100vh;
  background: #1a1a2e;
  font-family: 'Georgia', serif;
  user-select: none;
}

.ball {
  position: relative;
  width: 280px;
  height: 280px;
  border-radius: 50%;
  background: radial-gradient(circle at 35% 35%, #555, #000 70%);
  box-shadow:
    0 0 40px rgba(0,0,0,0.8),
    inset 0 0 60px rgba(0,0,0,0.5),
    4px 8px 24px rgba(0,0,0,0.9);
  cursor: pointer;
  transition: transform 0.1s ease;
}

.ball:hover {
  transform: scale(1.02);
}

.ball.shaking {
  animation: shake 0.5s ease-in-out;
}

@keyframes shake {
  0%   { transform: translate(0, 0) rotate(0deg); }
  15%  { transform: translate(-8px, 4px) rotate(-3deg); }
  30%  { transform: translate(8px, -4px) rotate(3deg); }
  45%  { transform: translate(-6px, 6px) rotate(-2deg); }
  60%  { transform: translate(6px, -6px) rotate(2deg); }
  75%  { transform: translate(-4px, 2px) rotate(-1deg); }
  90%  { transform: translate(4px, -2px) rotate(1deg); }
  100% { transform: translate(0, 0) rotate(0deg); }
}

.face {
  position: absolute;
  top: 50%;
  left: 50%;
  transform: translate(-50%, -50%);
  display: flex;
  align-items: center;
  justify-content: center;
  transition: opacity 0.4s ease;
}

.front {
  width: 100%;
  height: 100%;
}

.eight {
  font-size: 96px;
  font-weight: bold;
  color: white;
  text-shadow: 2px 2px 8px rgba(0,0,0,0.8);
  line-height: 1;
}

.window {
  opacity: 0;
  width: 100%;
  height: 100%;
}

.inner-circle {
  width: 140px;
  height: 140px;
  border-radius: 50%;
  background: radial-gradient(circle at 40% 40%, #1a3a6b, #0a1a3a);
  box-shadow: inset 0 0 20px rgba(0,0,0,0.8);
  display: flex;
  align-items: center;
  justify-content: center;
}

.triangle {
  width: 0;
  height: 0;
  border-left: 46px solid transparent;
  border-right: 46px solid transparent;
  border-bottom: 80px solid #1e4db7;
  position: relative;
  filter: drop-shadow(0 2px 4px rgba(0,0,0,0.5));
}

.answer {
  position: absolute;
  bottom: -72px;
  left: -38px;
  width: 76px;
  text-align: center;
  color: white;
  font-size: 11px;
  font-weight: bold;
  line-height: 1.2;
  text-transform: uppercase;
  letter-spacing: 0.03em;
}

.prompt {
  margin-top: 32px;
  color: #8888aa;
  font-size: 14px;
  letter-spacing: 0.05em;
  text-align: center;
  transition: opacity 0.3s ease;
}
$CSS$,

$JS$
var w = $('#' + id);

var responses = [
  // Positive
  'It is certain',
  'It is decidedly so',
  'Without a doubt',
  'Yes, definitely',
  'You may rely on it',
  'As I see it, yes',
  'Most likely',
  'Outlook good',
  'Yes',
  'Signs point to yes',
  // Neutral
  'Reply hazy, try again',
  'Ask again later',
  'Better not tell you now',
  'Cannot predict now',
  'Concentrate and ask again',
  // Negative
  "Don't count on it",
  'My reply is no',
  'My sources say no',
  'Outlook not so good',
  'Very doubtful'
];

var front  = w.find('.front');
var window_ = w.find('.window');
var answer = w.find('.answer');
var prompt = w.find('.prompt');
var ball   = w.find('.ball');
var shaking = false;

ball.on('click', function() {
  if (shaking) return;
  shaking = true;

  var response = responses[Math.floor(Math.random() * responses.length)];

  // Reset to 8 side before shaking
  front.css('opacity', 1);
  window_.css('opacity', 0);
  answer.text('');
  prompt.css('opacity', 0.4);

  ball.addClass('shaking');

  setTimeout(function() {
    // Flip to answer side
    front.css('opacity', 0);
    answer.text(response);
    window_.css('opacity', 1);
    prompt.text('Click again to ask another.').css('opacity', 1);
  }, 400);

  setTimeout(function() {
    ball.removeClass('shaking');
    shaking = false;
  }, 500);
});
$JS$
);

-- 2. Resource at /magic8ball
INSERT INTO endpoint.resource (path, mimetype_id, content)
VALUES (
  '/magic8ball',
  (SELECT id FROM endpoint.mimetype WHERE mimetype = 'text/html'),
  $RESOURCE$<!DOCTYPE html>
<html lang="en">
  <head>
    <script src='/system.js'></script>
    <title>Magic Eight Ball</title>
    <meta http-equiv="Content-type" content="text/html; charset=utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      *, *:before, *:after { box-sizing: border-box; margin: 0; padding: 0; }
      html, body { height: 100%; background: #1a1a2e; }
    </style>
  </head>
  <body></body>
  <script>
    System.import('/widget.js').then(function(widget) {
      var db = new AQ.Database('/endpoint/0.3', { evented: 'no' });
      window.endpoint = db;
      AQ.Widget.import('org.aquameta.games.magic8ball', 'm', db);
      $('body').append(widget('m:magic8ball'));
    });
  </script>
</html>
$RESOURCE$
);

-- 3. Bundle
SELECT bundle.create_repository('org.aquameta.games.magic8ball');

SELECT bundle.track_untracked_row(
  'org.aquameta.games.magic8ball',
  meta.row_id('widget', 'widget', ARRAY['id'], ARRAY[id::text])
) FROM widget.widget WHERE name = 'magic8ball';

SELECT bundle.track_untracked_row(
  'org.aquameta.games.magic8ball',
  meta.row_id('endpoint', 'resource', ARRAY['id'], ARRAY[id::text])
) FROM endpoint.resource WHERE path = '/magic8ball';

SELECT bundle.stage_tracked_rows('org.aquameta.games.magic8ball');
SELECT bundle.commit('org.aquameta.games.magic8ball', 'initial: magic eight ball widget', 'claude_code', 'claude@aquameta.org');
