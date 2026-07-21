import Vapor
import VaporToOpenAPI

/// Serves the generated OpenAPI document and a Scalar-based reference UI.
func registerOpenAPI(_ app: Application) throws {
    // Machine-readable spec, reflected from the annotated routes.
    app.get("openapi.json") { req in
        req.application.routes.openAPI(
            info: InfoObject(
                title: "ICICLE Insights API",
                description: "ICICLE Insights",
                version: "0.1.0",
            )
        )
    }
    .excludeFromOpenAPI()

    // Scalar reference UI, loaded from CDN and pointed at the spec above.
    app.get("docs") { _ in
        Response(
            status: .ok,
            headers: ["Content-Type": "text/html; charset=utf-8"],
            body: .init(string: scalarHTML),
        )
    }
    .excludeFromOpenAPI()
}

private let scalarHTML = """
<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>ICICLE Insights API</title>
  </head>
  <body>
    <script
      id="api-reference"
      data-url="/openapi.json"
      data-configuration='{"operationsSorter":"alpha","tagsSorter":"alpha"}'
    ></script>
    <script src="https://cdn.jsdelivr.net/npm/@scalar/api-reference"></script>
  </body>
</html>
"""
