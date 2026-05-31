{
  "targets": [
    {
      "target_name": "inklet_services",
      "conditions": [
        ["OS=='mac'", {
          "sources": ["services.mm"],
          "include_dirs": ["<!@(node -p \"require('node-addon-api').include\")"],
          "defines": ["NAPI_DISABLE_CPP_EXCEPTIONS"],
          "xcode_settings": {
            "OTHER_CFLAGS": ["-ObjC++", "-std=c++17"],
            "OTHER_LDFLAGS": ["-framework AppKit", "-framework Foundation"],
            "MACOSX_DEPLOYMENT_TARGET": "10.15"
          }
        }]
      ]
    }
  ]
}
