import Foundation
import InkletPresentationKit
import Testing

@Test
func storesSceneAndDownloadedImageForWidget() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "inklet-presentation-cache-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let presentation = try JSONDecoder().decode(
        GeneratedPresentationDTO.self,
        from: Data(
            """
            {
              "id":"presentation-1",
              "displayId":null,
              "contentIds":["content-1"],
              "mode":"auto",
              "state":"ready",
              "output":{
                "formats":["scene","png"],
                "preset":"macos-widget-medium",
                "viewport":{"width":360,"height":170},
                "colorMode":"color"
              },
              "scene":{
                "mediaType":"application/vnd.inklet.scene+json;version=1",
                "version":1,
                "data":{
                  "version":1,
                  "viewport":{"width":360,"height":170},
                  "background":"#ffffff",
                  "elements":[{
                    "id":"headline",
                    "type":"text",
                    "frame":{"x":20,"y":20,"width":320,"height":80},
                    "properties":{"text":"Hello widget"}
                  }]
                }
              },
              "renditions":[],
              "failure":null,
              "createdAt":"2026-08-29T20:00:00Z",
              "updatedAt":"2026-08-29T20:01:00Z"
            }
            """.utf8
        )
    )
    let image = Data([137, 80, 78, 71])
    let cache = PresentationCache(rootURL: root)

    try cache.store(presentation: presentation, imageData: image)
    let loaded = try #require(try cache.load())

    #expect(loaded.metadata.presentation.scene?.data.elements.first?.properties["text"] == .string("Hello widget"))
    #expect(loaded.imageData == image)
}
