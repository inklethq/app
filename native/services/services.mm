#include <napi.h>
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include <string>
#include <vector>
#include <utility>

static Napi::ThreadSafeFunction g_tsfn;

struct ServiceData {
  std::string text;
  std::vector<std::string> urls;
  std::vector<std::string> files;
  std::vector<std::pair<std::string, std::string>> images; // {base64, mime}
};

// -[NSString UTF8String] returns NULL for strings that can't be UTF-8 encoded;
// std::string(NULL) is UB. Pasteboard content is attacker-influenced, so guard.
static std::string toStd(NSString *s) {
  if (!s) return std::string();
  const char *c = [s UTF8String];
  return c ? std::string(c) : std::string();
}

@interface InkletServiceProvider : NSObject
- (void)sendToInklet:(NSPasteboard *)pboard userData:(NSString *)userData error:(NSString **)error;
@end

@implementation InkletServiceProvider
- (void)sendToInklet:(NSPasteboard *)pboard userData:(NSString *)userData error:(NSString **)error {
  ServiceData *data = new ServiceData();

  data->text = toStd([pboard stringForType:NSPasteboardTypeString]);

  NSArray *urls = [pboard readObjectsForClasses:@[ [NSURL class] ] options:nil];
  for (NSURL *u in urls) {
    if ([u isFileURL]) {
      std::string p = toStd([u path]);
      if (!p.empty()) data->files.push_back(p);
    } else {
      std::string s = toStd([u absoluteString]);
      if (!s.empty()) data->urls.push_back(s);
    }
  }

  if ([NSImage canInitWithPasteboard:pboard]) {
    NSData *png = [pboard dataForType:NSPasteboardTypePNG];
    if (!png) {
      NSData *tiff = [pboard dataForType:NSPasteboardTypeTIFF];
      if (tiff) {
        NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:tiff];
        png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
      }
    }
    if (png) {
      NSString *b64 = [png base64EncodedStringWithOptions:0];
      data->images.push_back({ toStd(b64), std::string("image/png") });
    }
  }

  if (g_tsfn) {
    napi_status st = g_tsfn.NonBlockingCall(data, [](Napi::Env env, Napi::Function cb, ServiceData *d) {
      Napi::Object obj = Napi::Object::New(env);
      if (!d->text.empty()) obj.Set("text", Napi::String::New(env, d->text));

      Napi::Array urls = Napi::Array::New(env, d->urls.size());
      for (size_t i = 0; i < d->urls.size(); i++) urls.Set(i, Napi::String::New(env, d->urls[i]));
      obj.Set("urls", urls);

      Napi::Array files = Napi::Array::New(env, d->files.size());
      for (size_t i = 0; i < d->files.size(); i++) files.Set(i, Napi::String::New(env, d->files[i]));
      obj.Set("files", files);

      Napi::Array images = Napi::Array::New(env, d->images.size());
      for (size_t i = 0; i < d->images.size(); i++) {
        Napi::Object im = Napi::Object::New(env);
        im.Set("base64", Napi::String::New(env, d->images[i].first));
        im.Set("mime", Napi::String::New(env, d->images[i].second));
        images.Set(i, im);
      }
      obj.Set("images", images);

      cb.Call({ obj });
      delete d;
    });
    // If the call could not be queued, the lambda never runs — free data here.
    if (st != napi_ok) delete data;
  } else {
    delete data;
  }
}
@end

static InkletServiceProvider *g_provider = nil;

Napi::Value Register(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (info.Length() < 1 || !info[0].IsFunction()) {
    Napi::TypeError::New(env, "register(callback) requires a function").ThrowAsJavaScriptException();
    return env.Undefined();
  }
  // Intentionally never Release()d: the provider must live for the whole app
  // lifetime. The retained event-loop ref is harmless in the Electron main
  // process (Electron/AppKit owns process lifetime, not node's loop draining).
  g_tsfn = Napi::ThreadSafeFunction::New(env, info[0].As<Napi::Function>(), "InkletServices", 0, 1);
  dispatch_async(dispatch_get_main_queue(), ^{
    g_provider = [[InkletServiceProvider alloc] init];
    [NSApp setServicesProvider:g_provider];
    NSUpdateDynamicServices();
    NSLog(@"[inklet] services provider registered");
  });
  return env.Undefined();
}

Napi::Object Init(Napi::Env env, Napi::Object exports) {
  exports.Set("register", Napi::Function::New(env, Register));
  return exports;
}

NODE_API_MODULE(inklet_services, Init)
