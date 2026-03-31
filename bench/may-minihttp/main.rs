#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

use std::io;
use std::sync::Arc;

use may_minihttp::{HttpService, HttpServiceFactory, Request, Response};
use may_postgres::{Client, Statement};
use yarte::Serialize;

#[derive(Serialize)]
struct WorldRow {
    id: i32,
    name: String,
}

struct PgConnectionPool {
    clients: Vec<PgConnection>,
}

impl PgConnectionPool {
    fn new(db_url: &'static str, size: usize) -> PgConnectionPool {
        let clients = (0..size)
            .map(|_| may::go!(move || PgConnection::new(db_url)))
            .collect::<Vec<_>>();
        let mut clients: Vec<_> = clients.into_iter().map(|t| t.join().unwrap()).collect();
        clients.sort_by(|a, b| (a.client.id() % size).cmp(&(b.client.id() % size)));
        PgConnectionPool { clients }
    }

    fn get_connection(&self, id: usize) -> PgConnection {
        let len = self.clients.len();
        let connection = &self.clients[id % len];
        PgConnection {
            client: connection.client.clone(),
            statement: connection.statement.clone(),
        }
    }
}

struct PgConnection {
    client: Client,
    statement: Arc<Statement>,
}

impl PgConnection {
    fn new(db_url: &str) -> Self {
        let client = may_postgres::connect(db_url).unwrap();
        let stmt = client.prepare("SELECT id, name FROM bench WHERE id = 1").unwrap();
        PgConnection {
            client,
            statement: Arc::new(stmt),
        }
    }

    fn get_row(&self) -> WorldRow {
        let rows = self.client.query(&*self.statement, &[]).unwrap();
        let row = &rows[0];
        WorldRow {
            id: row.get(0),
            name: row.get(1),
        }
    }
}

struct Techempower {
    db: PgConnection,
}

impl HttpService for Techempower {
    fn call(&mut self, req: Request, rsp: &mut Response) -> io::Result<()> {
        match req.path() {
            "/db" | "/" => {
                rsp.header("Content-Type: application/json");
                let row = self.db.get_row();
                row.to_bytes_mut(rsp.body_mut());
            }
            _ => {
                rsp.status_code(404, "Not Found");
            }
        }
        Ok(())
    }
}

struct HttpServer {
    db_pool: PgConnectionPool,
}

impl HttpServiceFactory for HttpServer {
    type Service = Techempower;

    fn new_service(&self, id: usize) -> Self::Service {
        Techempower {
            db: self.db_pool.get_connection(id),
        }
    }
}

fn main() {
    may::config().set_pool_capacity(1000).set_stack_size(0x1000);
    let db_url = std::env::var("DATABASE_URL")
        .unwrap_or_else(|_| "postgres://snek:snek@postgres/snek".to_string());
    let pool_size = num_cpus::get();
    println!("Starting may-minihttp: 0.0.0.0:8080, {} PG connections", pool_size);
    let server = HttpServer {
        db_pool: PgConnectionPool::new(Box::leak(db_url.into_boxed_str()), pool_size),
    };
    server.start("0.0.0.0:8080").unwrap().join().unwrap();
}
