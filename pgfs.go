//go:build (linux || freebsd)
package main

import (
    "context"
    "log"
    "os"
    "os/exec"
    "fmt"
    "strings"
    "syscall"

    "github.com/jackc/pgx/v4/pgxpool"
    // "github.com/jackc/pgx/v4"
    "github.com/lib/pq"

    "bazil.org/fuse"
    "bazil.org/fuse/fs"
)


func pgfs(config tomlConfig, dbpool *pgxpool.Pool, fuseDone chan bool) {
    if ! config.PGFS.Enabled {
        log.Printf("PGFS is not enabled.")
    } else {

        log.Printf("Mounting PGFS Filesystem: %s\n\n", config.PGFS.MountDirectory)

        // Clear any stale mount left by a previous crashed instance.
        exec.Command("fusermount", "-uz", config.PGFS.MountDirectory).Run()

        c, err := fuse.Mount(
            config.PGFS.MountDirectory,
            fuse.FSName("pgfsfs"),
            fuse.Subtype("pgfs"),
        )
        if err != nil {
            log.Fatal(err)
        }
        defer c.Close()

        err = fs.Serve(c, FS{dbpool: dbpool})
        if err != nil {
            log.Fatal(err)
        }

        fuseDone <- true
    }
}



//
// File System
//


type FS struct{
    dbpool *pgxpool.Pool
}

func (f FS) Root() (fs.Node, error) {
    return Dir{f}, nil
}

//
// Root Directory
//

type Dir struct{
    fs FS
}

func (Dir) Attr(ctx context.Context, a *fuse.Attr) error {
    a.Inode = 1
    a.Uid = uint32(syscall.Geteuid())
    a.Gid = uint32(syscall.Getegid())
    a.Mode = os.ModeDir | 0o500
    return nil
}

func (d Dir) Lookup(ctx context.Context, name string) (fs.Node, error) {
    var exists bool
    q := fmt.Sprintf("select exists(select 1 from meta.schema where name=%s)", pq.QuoteLiteral(name))
    err := d.fs.dbpool.QueryRow(context.Background(), q).Scan(&exists)
    if err != nil {
        log.Println("Dir Lookup: Error querying database: ", err)
        return nil, fuse.ENOENT
    }
    if exists {
        return SchemaDir{d.fs, name}, nil
    }
    return nil, fuse.ENOENT

}

func (d Dir) ReadDirAll(ctx context.Context) ([]fuse.Dirent, error) {
    q := fmt.Sprintf("select name from meta.schema")
    rows, err := d.fs.dbpool.Query(context.Background(), q)

    if err != nil {
        log.Fatal("Dir ReadDirAll: Error querying database: ", err)
    }
    defer rows.Close()

    var dirDirs []fuse.Dirent
    for rows.Next() {
        var name string

        err := rows.Scan(&name)
        if err != nil {
            log.Fatal("Dir ReadDirAll: Error scanning row", err)
            continue
        }

        // log.Println("Schema:", name)
        dirDirs = append(dirDirs, fuse.Dirent{
            Inode: 2,
            Name: name,
            Type: fuse.DT_Dir,
        })
    }


    if rows.Err() != nil {
        log.Fatal("Dir ReadDirAll: Error iterating rows", rows.Err())
    }

    return append(dirDirs,
        fuse.Dirent{Name: ".", Type: fuse.DT_Dir},
        fuse.Dirent{Name: "..", Type: fuse.DT_Dir}), nil
}


//
// SchemaDir
//

type SchemaDir struct{
    fs FS
    schema_name string
}

func (d SchemaDir) Attr(ctx context.Context, a *fuse.Attr) error {
    a.Inode = 1
    a.Uid = uint32(syscall.Geteuid())
    a.Gid = uint32(syscall.Getegid())
    a.Mode = os.ModeDir | 0o500
    return nil
}

func (d SchemaDir) Lookup(ctx context.Context, name string) (fs.Node, error) {
    var exists bool
    var pk_column_name string

    pkQ := fmt.Sprintf("select (primary_key_column_ids[1]).name as pk_column_name from meta.relation where schema_name=%s and name=%s and primary_key_column_ids is not null",
        pq.QuoteLiteral(d.schema_name),
        pq.QuoteLiteral(name))

    // check that relation exists
    existsQ := fmt.Sprintf("select exists(%s)", pkQ)
    err := d.fs.dbpool.QueryRow(context.Background(), existsQ).Scan(&exists)
    if err != nil {
        log.Fatal("Error in SchemaDir Lookup exists: ", err)
        return nil, fuse.ENOENT
    }

    if !exists {
        return nil, fuse.ENOENT
    }

    // get its primary key, for use as variable in TableDir struct
    err = d.fs.dbpool.QueryRow(context.Background(), pkQ).Scan(&pk_column_name)
    if err != nil {
        log.Fatal("Error in SchemaDir Lookup pk query: ", err)
        return nil, fuse.ENOENT
    }
    return TableDir{d.fs, d.schema_name, name, pk_column_name}, nil
}

func (d SchemaDir) ReadDirAll(ctx context.Context) ([]fuse.Dirent, error) {
     q := fmt.Sprintf("select name from meta.relation where schema_name=%s and primary_key_column_ids is not null",
         pq.QuoteLiteral(d.schema_name))
    rows, err := d.fs.dbpool.Query(context.Background(), q)

    if err != nil {
        log.Fatal("SchemaDir ReadDirAll(): Error querying database: ", err)
    }
    defer rows.Close()

    var dirDirs []fuse.Dirent
    for rows.Next() {
        var name string

        err := rows.Scan(&name)
        if err != nil {
            log.Fatal("SchemaDir ReadDirAll(): Error scanning row", err)
            continue
        }

        // log.Println("Relation: ", name)
        dirDirs = append(dirDirs, fuse.Dirent{
            Inode: 2,
            Name: name,
            Type: fuse.DT_Dir,
        })
    }

    if rows.Err() != nil {
        log.Fatal("SchemaDir ReadDirAll(): Error iterating rows", rows.Err())
    }

    return append(dirDirs,
        fuse.Dirent{Name: ".", Type: fuse.DT_Dir},
        fuse.Dirent{Name: "..", Type: fuse.DT_Dir}), nil
}


//
// TableDir
//

type TableDir struct{
    fs FS
    schema_name string
    table_name string
    pk_column_name string
}

func (TableDir) Attr(ctx context.Context, a *fuse.Attr) error {
    a.Inode = 1
    a.Uid = uint32(syscall.Geteuid())
    a.Gid = uint32(syscall.Getegid())
    a.Mode = os.ModeDir | 0o500
    return nil
}

func (d TableDir) Lookup(ctx context.Context, name string) (fs.Node, error) {
    if name == "by-name" {
        labelCol := getLabelColumn(ctx, d.fs.dbpool, d.schema_name, d.table_name)
        if labelCol != "" && labelCol != d.pk_column_name {
            return ByNameDir{d.fs, d.schema_name, d.table_name, d.pk_column_name, labelCol}, nil
        }
        return nil, fuse.ENOENT
    }

    var exists bool
    q := fmt.Sprintf("select exists(select 1 from %s.%s where %s::text=%s)",
        pq.QuoteIdentifier(d.schema_name),
        pq.QuoteIdentifier(d.table_name),
        pq.QuoteIdentifier(d.pk_column_name),
        pq.QuoteLiteral(name))
    err := d.fs.dbpool.QueryRow(context.Background(), q).Scan(&exists)
    if err != nil {
        log.Println("TableDir Lookup(): Error querying database: ", err)
        return nil, fuse.ENOENT
    }
    if exists {
        return RowDir{d.fs, d.schema_name, d.table_name, d.pk_column_name, name}, nil
    }
    return nil, fuse.ENOENT
}

func (d TableDir) ReadDirAll(ctx context.Context) ([]fuse.Dirent, error) {
     q := fmt.Sprintf("select %s as pk_value from %s.%s",
         pq.QuoteIdentifier(d.pk_column_name),
         pq.QuoteIdentifier(d.schema_name),
         pq.QuoteIdentifier(d.table_name))

    rows, err := d.fs.dbpool.Query(context.Background(), q)
    if err != nil {
        log.Fatal("TableDir ReadDirAll(): Error querying database: ", err)
    }
    defer rows.Close()

    var dirDirs []fuse.Dirent
    for rows.Next() {
        var pk_value string

        err := rows.Scan(&pk_value)
        if err != nil {
            log.Fatal("TableDir ReadDirAll(): Error scanning row", err)
            continue
        }

        // log.Println("Primary Key:", pk_value)
        dirDirs = append(dirDirs, fuse.Dirent{
            Inode: 2,
            Name: pk_value,
            Type: fuse.DT_Dir,
        })
    }

    if rows.Err() != nil {
        log.Fatal("TableDir ReadDirAll(): Error iterating rows", rows.Err())
    }

    labelCol := getLabelColumn(ctx, d.fs.dbpool, d.schema_name, d.table_name)
    if labelCol != "" && labelCol != d.pk_column_name {
        dirDirs = append(dirDirs, fuse.Dirent{
            Inode: 2,
            Name:  "by-name",
            Type:  fuse.DT_Dir,
        })
    }

    return dirDirs, nil
}


//
// getLabelColumn
//
// Calls navigation.label_column() to find the best human-readable label column
// for a relation. Returns "" if the navigation extension is not installed or
// the relation has no suitable label column. Never crashes the daemon.
//

func getLabelColumn(ctx context.Context, dbpool *pgxpool.Pool, schema, table string) string {
    var labelCol *string
    q := fmt.Sprintf("select navigation.label_column(%s, %s)",
        pq.QuoteLiteral(schema),
        pq.QuoteLiteral(table))
    err := dbpool.QueryRow(ctx, q).Scan(&labelCol)
    if err != nil || labelCol == nil {
        return ""
    }
    return *labelCol
}


//
// ByNameDir
//
// Virtual directory inside a TableDir that exposes rows by their label column
// value instead of UUID. e.g. pgfs/widget/widget/by-name/my_widget/html
//
// Label column is determined by navigation.label_column() — probe order:
// name > title > label > description > path > first PK.
// Only present when the label column differs from the PK (otherwise by-name
// would just mirror the parent UUID listing).
//
// Non-unique label values: ReadDirAll returns DISTINCT labels; Lookup picks
// the row with the lowest PK deterministically. Later collisions are hidden
// from by-name but remain reachable via the UUID path.
//

type ByNameDir struct {
    fs             FS
    schema_name    string
    table_name     string
    pk_column_name string
    label_column   string
}

func (ByNameDir) Attr(ctx context.Context, a *fuse.Attr) error {
    a.Inode = 1
    a.Uid = uint32(syscall.Geteuid())
    a.Gid = uint32(syscall.Getegid())
    a.Mode = os.ModeDir | 0o500
    return nil
}

func (d ByNameDir) Lookup(ctx context.Context, name string) (fs.Node, error) {
    // FUSE path components cannot contain '/' — skip lookup for such values.
    if strings.Contains(name, "/") {
        return nil, fuse.ENOENT
    }
    var pkValue string
    q := fmt.Sprintf(
        "select %s::text from %s.%s where %s::text=%s and %s is not null order by %s limit 1",
        pq.QuoteIdentifier(d.pk_column_name),
        pq.QuoteIdentifier(d.schema_name),
        pq.QuoteIdentifier(d.table_name),
        pq.QuoteIdentifier(d.label_column),
        pq.QuoteLiteral(name),
        pq.QuoteIdentifier(d.label_column),
        pq.QuoteIdentifier(d.pk_column_name),
    )
    err := d.fs.dbpool.QueryRow(ctx, q).Scan(&pkValue)
    if err != nil {
        return nil, fuse.ENOENT
    }
    return RowDir{d.fs, d.schema_name, d.table_name, d.pk_column_name, pkValue}, nil
}

func (d ByNameDir) ReadDirAll(ctx context.Context) ([]fuse.Dirent, error) {
    q := fmt.Sprintf(
        "select distinct %s::text from %s.%s where %s is not null order by 1",
        pq.QuoteIdentifier(d.label_column),
        pq.QuoteIdentifier(d.schema_name),
        pq.QuoteIdentifier(d.table_name),
        pq.QuoteIdentifier(d.label_column),
    )
    rows, err := d.fs.dbpool.Query(ctx, q)
    if err != nil {
        log.Println("ByNameDir ReadDirAll(): Error querying database: ", err)
        return nil, fuse.EIO
    }
    defer rows.Close()

    var dirDirs []fuse.Dirent
    for rows.Next() {
        var labelValue string
        if err := rows.Scan(&labelValue); err != nil {
            log.Println("ByNameDir ReadDirAll(): Error scanning row: ", err)
            continue
        }
        // FUSE directory entry names cannot contain '/'; skip such labels.
        if strings.Contains(labelValue, "/") {
            continue
        }
        dirDirs = append(dirDirs, fuse.Dirent{
            Inode: 2,
            Name:  labelValue,
            Type:  fuse.DT_Dir,
        })
    }
    if rows.Err() != nil {
        log.Println("ByNameDir ReadDirAll(): Error iterating rows: ", rows.Err())
        return nil, fuse.EIO
    }
    return dirDirs, nil
}




//
// RowDir
//

type RowDir struct{
    fs FS
    schema_name string
    table_name string
    pk_column_name string
    pk_value string
}

func (RowDir) Attr(ctx context.Context, a *fuse.Attr) error {
    a.Inode = 1
    a.Uid = uint32(syscall.Geteuid())
    a.Gid = uint32(syscall.Getegid())
    a.Mode = os.ModeDir | 0o500
    return nil
}

/*
func (d RowDir) Lookup(ctx context.Context, name string) (fs.Node, error) {
        return FieldFile{d.fs, d.schema_name, d.table_name, name, d.pk_column_name, d.pk_value}, nil
}
*/
func (d RowDir) Lookup(ctx context.Context, name string) (fs.Node, error) {
    // log.Println("RowDir Lookup(): name=", name)
    var columnExists bool
    var rowExists bool

    // check that this column exists (we could probably make this a lot faster by sending garbage queries to the db)
    existsQ := fmt.Sprintf("select exists(select 1 from meta.relation_column where schema_name=%s and relation_name=%s and name=%s)",
        pq.QuoteLiteral(d.schema_name),
        pq.QuoteLiteral(d.table_name),
        pq.QuoteLiteral(name))
    // log.Println("existsQ", existsQ)

    err := d.fs.dbpool.QueryRow(context.Background(), existsQ).Scan(&columnExists)
    if err != nil {
        log.Fatal("RowDir Lookup(): Error in column exists check: ", err)
    }
    if !columnExists {
        return nil, fuse.ENOENT
    }

    // check that row exists
    q := fmt.Sprintf("select exists(select %s from %s.%s where %s::text=%s)",
        pq.QuoteIdentifier(name),
        pq.QuoteIdentifier(d.schema_name),
        pq.QuoteIdentifier(d.table_name),
        pq.QuoteIdentifier(d.pk_column_name),
        pq.QuoteLiteral(d.pk_value))
    err = d.fs.dbpool.QueryRow(context.Background(), q).Scan(&rowExists)
    if err != nil {
        log.Fatal("RowDir Lookup(): Error in row exists check: ", err)
    }
    if !rowExists {
        return nil, fuse.ENOENT
    }

    f := FieldFile{
        fs: d.fs,
        schema_name: d.schema_name,
        table_name: d.table_name,
        column_name: name,
        pk_column_name: d.pk_column_name,
        pk_value: d.pk_value,
    }
    return f, nil;
    // was: return FieldFile{d.fs, d.schema_name, d.table_name, name, d.pk_column_name, d.pk_value}, nil
}


func (d RowDir) ReadDirAll(ctx context.Context) ([]fuse.Dirent, error) {
     q := fmt.Sprintf("select name as column_name from meta.column where schema_name=%s and relation_name=%s",
         pq.QuoteLiteral(d.schema_name),
         pq.QuoteLiteral(d.table_name))
    rows, err := d.fs.dbpool.Query(context.Background(), q)

    if err != nil {
        log.Fatal("RowDir ReadDirAll(): Error querying database: ", err)
    }
    defer rows.Close()

    var dirDirs []fuse.Dirent
    for rows.Next() {
        var column_name string

        err := rows.Scan(&column_name)
        if err != nil {
            log.Fatal("RowDir ReadDirAll(): Error scanning row: ", err)
            continue
        }

        // log.Println("Schema:", column_name)
        dirDirs = append(dirDirs, fuse.Dirent{
            Inode: 2,
            Name: column_name,
            Type: fuse.DT_File,
        })
    }

    if rows.Err() != nil {
        log.Fatal("RowDir ReadDirAll(): Error iterating rows", rows.Err())
    }

    return append(dirDirs,
        fuse.Dirent{Name: ".", Type: fuse.DT_Dir},
        fuse.Dirent{Name: "..", Type: fuse.DT_Dir}), nil
}


//
// FieldFile
//
var fileBuffers = make(map[string]string)

type FieldFile struct{
    fs FS
    schema_name string
    table_name string
    column_name string
    pk_column_name string
    pk_value string
}

func (ff FieldFile) Attr(ctx context.Context, a *fuse.Attr) error {
    var octet_length int

    q := fmt.Sprintf("select coalesce(octet_length(%s::text)::integer, 0) as octet_length from %s.%s where %s = %s",
         pq.QuoteIdentifier(ff.column_name),
         pq.QuoteIdentifier(ff.schema_name),
         pq.QuoteIdentifier(ff.table_name),
         pq.QuoteIdentifier(ff.pk_column_name),
         pq.QuoteLiteral(ff.pk_value))

    // fmt.Println(q)

    err := ff.fs.dbpool.QueryRow(context.Background(), q).Scan(&octet_length)

    if err != nil {
        log.Fatal("FileField Attr(): Error querying database: ", err)
    }

    a.Inode = 2
    a.Size = uint64(octet_length)
    a.Uid = uint32(syscall.Geteuid())
    a.Gid = uint32(syscall.Getegid())
    a.Mode = 0o644

    return nil
}

func (ff FieldFile) ReadAll(ctx context.Context) ([]byte, error) {
    var content string

    q := fmt.Sprintf("select %s::text as content from %s.%s where %s = %s",
         pq.QuoteIdentifier(ff.column_name),
         pq.QuoteIdentifier(ff.schema_name),
         pq.QuoteIdentifier(ff.table_name),
         pq.QuoteIdentifier(ff.pk_column_name),
         pq.QuoteLiteral(ff.pk_value))

    err := ff.fs.dbpool.QueryRow(context.Background(), q).Scan(&content)

    if err != nil {
        log.Fatal("FileField ReadDirAll(): Error querying database: ", err)
    }

    return []byte(content), nil
}


func (ff FieldFile) Write(ctx context.Context, req *fuse.WriteRequest, resp *fuse.WriteResponse) error {
    var key = ff.schema_name+"/"+ff.table_name+"/"+ff.pk_value+"/"+ff.column_name

    // Grow buffer to accommodate write at offset
    end := int(req.Offset) + len(req.Data)
    buf := []byte(fileBuffers[key])
    if end > len(buf) {
        grown := make([]byte, end)
        copy(grown, buf)
        buf = grown
    }
    copy(buf[req.Offset:], req.Data)
    fileBuffers[key] = string(buf)

    resp.Size = len(req.Data)
    return nil
}


func (ff FieldFile) Fsync(ctx context.Context, req *fuse.FsyncRequest) error {
    var key = ff.schema_name+"/"+ff.table_name+"/"+ff.pk_value+"/"+ff.column_name

    // log.Printf("!!!!!!!! Fsync called:\n    fileBuffers[%s] %s", key, fileBuffers[key]);

    q := fmt.Sprintf("update %s.%s set %s = %s where %s = %s",
         pq.QuoteIdentifier(ff.schema_name),
         pq.QuoteIdentifier(ff.table_name),
         pq.QuoteIdentifier(ff.column_name),
         pq.QuoteLiteral(fileBuffers[key]),
         pq.QuoteIdentifier(ff.pk_column_name),
         pq.QuoteLiteral(ff.pk_value))
    _, err := ff.fs.dbpool.Exec(context.Background(), q)

    // log.Println("Fsync field update q: ",q)
    if err != nil {
        // Handle error
        log.Printf("FieldFile Flush(): update stmt failed. ",q,err)
    }
    fileBuffers[key] = ""

    return nil
}


func (ff FieldFile) Flush(ctx context.Context, req *fuse.FlushRequest) error {
    // Flush fires on file close; writes are committed to DB on explicit Fsync.
    // Nothing to do here.
    return nil
}
