use actix_web::{web, App, HttpResponse, HttpServer};
use std::env;

async fn hello() -> HttpResponse {
    HttpResponse::Ok()
        .insert_header(("Content-Type", "application/json"))
        .insert_header(("Connection", "close"))
        .body("{\"message\":\"hello\"}")
}

async fn health() -> HttpResponse {
    HttpResponse::Ok()
        .insert_header(("Content-Type", "application/json"))
        .insert_header(("Connection", "close"))
        .body("{\"status\":\"ok\"}")
}

async fn greet(path: web::Path<String>) -> HttpResponse {
    let name = path.into_inner();
    HttpResponse::Ok()
        .insert_header(("Content-Type", "application/json"))
        .insert_header(("Connection", "close"))
        .body(format!("{{\"message\":\"hello {name}\"}}"))
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    let port: u16 = env::args()
        .nth(1)
        .or_else(|| env::var("PORT").ok())
        .and_then(|s| s.parse().ok())
        .unwrap_or(8080);

    eprintln!("rust control listening on http://127.0.0.1:{port}/");

    HttpServer::new(|| {
        App::new()
            .route("/", web::get().to(hello))
            .route("/health", web::get().to(health))
            .route("/greet/{name}", web::get().to(greet))
    })
    .bind(("0.0.0.0", port))?
    .run()
    .await
}
