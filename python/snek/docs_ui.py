"""Minimal HTML templates for Swagger UI and ReDoc.

No bundled assets — everything loads from CDN.
"""


def swagger_html(openapi_url: str, title: str = "snek — API docs") -> str:
    """Return a self-contained HTML page that renders Swagger UI."""
    return f"""\
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{title}</title>
  <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css">
  <style>body {{ margin: 0; }} .topbar {{ display: none; }}</style>
</head>
<body>
  <div id="swagger-ui"></div>
  <script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
  <script>
    SwaggerUIBundle({{
      url: "{openapi_url}",
      dom_id: "#swagger-ui",
      presets: [SwaggerUIBundle.presets.apis, SwaggerUIBundle.SwaggerUIStandalonePreset],
      layout: "StandaloneLayout",
      deepLinking: true,
    }});
  </script>
</body>
</html>"""


def redoc_html(openapi_url: str, title: str = "snek — API docs") -> str:
    """Return a self-contained HTML page that renders ReDoc."""
    return f"""\
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{title}</title>
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;600&display=swap" rel="stylesheet">
  <style>body {{ margin: 0; }}</style>
</head>
<body>
  <redoc spec-url="{openapi_url}"></redoc>
  <script src="https://cdn.redoc.ly/redoc/latest/bundles/redoc.standalone.js"></script>
</body>
</html>"""
