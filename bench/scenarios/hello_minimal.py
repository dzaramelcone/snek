import snek

app = snek.App()

@app.get("/")
async def hello():
    return {"message": "hello"}

if __name__ == "__main__":
    app.run(module_ref="hello_minimal:app")
