// Copyright (c) 2012 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "content/browser/web_contents/web_drag_source_mac.h"

#include <sys/param.h>

#include "base/bind.h"
#include "base/file_path.h"
#include "base/pickle.h"
#include "base/string_util.h"
#include "base/sys_string_conversions.h"
#include "base/threading/thread.h"
#include "base/threading/thread_restrictions.h"
#include "base/utf_string_conversions.h"
#include "content/browser/browser_thread_impl.h"
#include "content/browser/download/drag_download_file.h"
#include "content/browser/download/drag_download_util.h"
#include "content/browser/renderer_host/render_view_host_impl.h"
#include "content/browser/web_contents/web_contents_impl.h"
#include "content/public/browser/content_browser_client.h"
#include "content/public/common/content_client.h"
#include "content/public/common/url_constants.h"
#include "grit/ui_resources.h"
#include "net/base/escape.h"
#include "net/base/file_stream.h"
#include "net/base/net_util.h"
#include "ui/base/clipboard/custom_data_helper.h"
#include "ui/base/dragdrop/cocoa_dnd_util.h"
#include "ui/gfx/image/image.h"
#include "ui/gfx/mac/nsimage_cache.h"
#include "webkit/glue/webdropdata.h"

using base::SysNSStringToUTF8;
using base::SysUTF8ToNSString;
using base::SysUTF16ToNSString;
using content::BrowserThread;
using content::DragDownloadFile;
using content::PromiseFileFinalizer;
using content::RenderViewHostImpl;
using net::FileStream;

namespace {

// An unofficial standard pasteboard title type to be provided alongside the
// |NSURLPboardType|.
NSString* const kNSURLTitlePboardType = @"public.url-name";

// Converts a string16 into a FilePath. Use this method instead of
// -[NSString fileSystemRepresentation] to prevent exceptions from being thrown.
// See http://crbug.com/78782 for more info.
FilePath FilePathFromFilename(const string16& filename) {
  NSString* str = SysUTF16ToNSString(filename);
  char buf[MAXPATHLEN];
  if (![str getFileSystemRepresentation:buf maxLength:sizeof(buf)])
    return FilePath();
  return FilePath(buf);
}

// Returns a filename appropriate for the drop data
// TODO(viettrungluu): Refactor to make it common across platforms,
// and move it somewhere sensible.
FilePath GetFileNameFromDragData(const WebDropData& drop_data) {
  FilePath file_name(FilePathFromFilename(drop_data.file_description_filename));

  // Images without ALT text will only have a file extension so we need to
  // synthesize one from the provided extension and URL.
  if (file_name.empty()) {
    // Retrieve the name from the URL.
    string16 suggested_filename =
        net::GetSuggestedFilename(drop_data.url, "", "", "", "", "");
    const std::string extension = file_name.Extension();
    file_name = FilePathFromFilename(suggested_filename);
    file_name = file_name.ReplaceExtension(extension);
  }

  return file_name;
}

// This helper's sole task is to write out data for a promised file; the caller
// is responsible for opening the file. It takes the drop data and an open file
// stream.
void PromiseWriterHelper(const WebDropData& drop_data,
                         scoped_ptr<FileStream> file_stream) {
  DCHECK(file_stream);
  file_stream->WriteSync(drop_data.file_contents.data(),
                         drop_data.file_contents.length());
}

}  // namespace


@interface WebDragSource(Private)

- (void)fillPasteboard;
- (NSImage*)dragImage;

@end  // @interface WebDragSource(Private)


@implementation WebDragSource

- (id)initWithContents:(content::WebContentsImpl*)contents
                  view:(NSView*)contentsView
              dropData:(const WebDropData*)dropData
                 image:(NSImage*)image
                offset:(NSPoint)offset
            pasteboard:(NSPasteboard*)pboard
     dragOperationMask:(NSDragOperation)dragOperationMask {
  if ((self = [super init])) {
    contents_ = contents;
    DCHECK(contents_);

    contentsView_ = contentsView;
    DCHECK(contentsView_);

    dropData_.reset(new WebDropData(*dropData));
    DCHECK(dropData_.get());

    dragImage_.reset([image retain]);
    imageOffset_ = offset;

    pasteboard_.reset([pboard retain]);
    DCHECK(pasteboard_.get());

    dragOperationMask_ = dragOperationMask;

    fileExtension_ = nil;

    [self fillPasteboard];
  }

  return self;
}

- (void)clearWebContentsView {
  contents_ = nil;
  contentsView_ = nil;
}

- (NSDragOperation)draggingSourceOperationMaskForLocal:(BOOL)isLocal {
  return dragOperationMask_;
}

- (void)lazyWriteToPasteboard:(NSPasteboard*)pboard forType:(NSString*)type {
  // NSHTMLPboardType requires the character set to be declared. Otherwise, it
  // assumes US-ASCII. Awesome.
  const string16 kHtmlHeader = ASCIIToUTF16(
      "<meta http-equiv=\"Content-Type\" content=\"text/html;charset=UTF-8\">");

  // Be extra paranoid; avoid crashing.
  if (!dropData_.get()) {
    NOTREACHED();
    return;
  }

  // HTML.
  if ([type isEqualToString:NSHTMLPboardType]) {
    DCHECK(!dropData_->html.string().empty());
    // See comment on |kHtmlHeader| above.
    [pboard setString:SysUTF16ToNSString(kHtmlHeader + dropData_->html.string())
              forType:NSHTMLPboardType];

  // URL.
  } else if ([type isEqualToString:NSURLPboardType]) {
    DCHECK(dropData_->url.is_valid());
    NSURL* url = [NSURL URLWithString:SysUTF8ToNSString(dropData_->url.spec())];
    // If NSURL creation failed, check for a badly-escaped JavaScript URL.
    // Strip out any existing escapes and then re-escape uniformly.
    if (!url && dropData_->url.SchemeIs(chrome::kJavaScriptScheme)) {
      net::UnescapeRule::Type unescapeRules =
          net::UnescapeRule::SPACES |
          net::UnescapeRule::URL_SPECIAL_CHARS |
          net::UnescapeRule::CONTROL_CHARS;
      std::string unescapedUrlString =
          net::UnescapeURLComponent(dropData_->url.spec(), unescapeRules);
      std::string escapedUrlString =
          net::EscapeUrlEncodedData(unescapedUrlString, false);
      url = [NSURL URLWithString:SysUTF8ToNSString(escapedUrlString)];
    }
    [url writeToPasteboard:pboard];
  // URL title.
  } else if ([type isEqualToString:kNSURLTitlePboardType]) {
    [pboard setString:SysUTF16ToNSString(dropData_->url_title)
              forType:kNSURLTitlePboardType];

  // File contents.
  } else if ([type isEqualToString:NSFileContentsPboardType] ||
      (fileExtension_ &&
       [type isEqualToString:NSCreateFileContentsPboardType(fileExtension_)])) {
    // TODO(viettrungluu: find something which is known to accept
    // NSFileContentsPboardType to check that this actually works!
    scoped_nsobject<NSFileWrapper> file_wrapper(
        [[NSFileWrapper alloc] initRegularFileWithContents:[NSData
                dataWithBytes:dropData_->file_contents.data()
                       length:dropData_->file_contents.length()]]);
    [file_wrapper setPreferredFilename:SysUTF8ToNSString(
            GetFileNameFromDragData(*dropData_).value())];
    [pboard writeFileWrapper:file_wrapper];

  // TIFF.
  } else if ([type isEqualToString:NSTIFFPboardType]) {
    // TODO(viettrungluu): This is a bit odd since we rely on Cocoa to render
    // our image into a TIFF. This is also suboptimal since this is all done
    // synchronously. I'm not sure there's much we can easily do about it.
    scoped_nsobject<NSImage> image(
        [[NSImage alloc] initWithData:[NSData
                dataWithBytes:dropData_->file_contents.data()
                       length:dropData_->file_contents.length()]]);
    [pboard setData:[image TIFFRepresentation] forType:NSTIFFPboardType];

  // Plain text.
  } else if ([type isEqualToString:NSStringPboardType]) {
    DCHECK(!dropData_->text.string().empty());
    [pboard setString:SysUTF16ToNSString(dropData_->text.string())
              forType:NSStringPboardType];

  // Custom MIME data.
  } else if ([type isEqualToString:ui::kWebCustomDataPboardType]) {
    Pickle pickle;
    ui::WriteCustomDataToPickle(dropData_->custom_data, &pickle);
    [pboard setData:[NSData dataWithBytes:pickle.data() length:pickle.size()]
            forType:ui::kWebCustomDataPboardType];

  // Oops!
  } else {
    // Unknown drag pasteboard type.
    NOTREACHED();
  }
}

- (NSPoint)convertScreenPoint:(NSPoint)screenPoint {
  DCHECK([contentsView_ window]);
  NSPoint basePoint = [[contentsView_ window] convertScreenToBase:screenPoint];
  return [contentsView_ convertPoint:basePoint fromView:nil];
}

- (void)startDrag {
  NSEvent* currentEvent = [NSApp currentEvent];

  // Synthesize an event for dragging, since we can't be sure that
  // [NSApp currentEvent] will return a valid dragging event.
  NSWindow* window = [contentsView_ window];
  NSPoint position = [window mouseLocationOutsideOfEventStream];
  NSTimeInterval eventTime = [currentEvent timestamp];
  NSEvent* dragEvent = [NSEvent mouseEventWithType:NSLeftMouseDragged
                                          location:position
                                     modifierFlags:NSLeftMouseDraggedMask
                                         timestamp:eventTime
                                      windowNumber:[window windowNumber]
                                           context:nil
                                       eventNumber:0
                                        clickCount:1
                                          pressure:1.0];

  if (dragImage_) {
    position.x -= imageOffset_.x;
    // Deal with Cocoa's flipped coordinate system.
    position.y -= [dragImage_.get() size].height - imageOffset_.y;
  }
  // Per kwebster, offset arg is ignored, see -_web_DragImageForElement: in
  // third_party/WebKit/Source/WebKit/mac/Misc/WebNSViewExtras.m.
  [window dragImage:[self dragImage]
                 at:position
             offset:NSZeroSize
              event:dragEvent
         pasteboard:pasteboard_
             source:contentsView_
          slideBack:YES];
}

- (void)endDragAt:(NSPoint)screenPoint
        operation:(NSDragOperation)operation {
  if (!contents_)
    return;
  contents_->SystemDragEnded();

  RenderViewHostImpl* rvh = static_cast<RenderViewHostImpl*>(
      contents_->GetRenderViewHost());
  if (rvh) {
    // Convert |screenPoint| to view coordinates and flip it.
    NSPoint localPoint = NSMakePoint(0, 0);
    if ([contentsView_ window])
      localPoint = [self convertScreenPoint:screenPoint];
    NSRect viewFrame = [contentsView_ frame];
    localPoint.y = viewFrame.size.height - localPoint.y;
    // Flip |screenPoint|.
    NSRect screenFrame = [[[contentsView_ window] screen] frame];
    screenPoint.y = screenFrame.size.height - screenPoint.y;

    // If AppKit returns a copy and move operation, mask off the move bit
    // because WebCore does not understand what it means to do both, which
    // results in an assertion failure/renderer crash.
    if (operation == (NSDragOperationMove | NSDragOperationCopy))
      operation &= ~NSDragOperationMove;

    rvh->DragSourceEndedAt(localPoint.x, localPoint.y,
                           screenPoint.x, screenPoint.y,
                           static_cast<WebKit::WebDragOperation>(operation));
  }

  // Make sure the pasteboard owner isn't us.
  [pasteboard_ declareTypes:[NSArray array] owner:nil];
}

- (void)moveDragTo:(NSPoint)screenPoint {
  if (!contents_)
    return;
  RenderViewHostImpl* rvh = static_cast<RenderViewHostImpl*>(
      contents_->GetRenderViewHost());
  if (rvh) {
    // Convert |screenPoint| to view coordinates and flip it.
    NSPoint localPoint = NSMakePoint(0, 0);
    if ([contentsView_ window])
      localPoint = [self convertScreenPoint:screenPoint];
    NSRect viewFrame = [contentsView_ frame];
    localPoint.y = viewFrame.size.height - localPoint.y;
    // Flip |screenPoint|.
    NSRect screenFrame = [[[contentsView_ window] screen] frame];
    screenPoint.y = screenFrame.size.height - screenPoint.y;

    rvh->DragSourceMovedTo(localPoint.x, localPoint.y,
                           screenPoint.x, screenPoint.y);
  }
}

- (NSString*)dragPromisedFileTo:(NSString*)path {
  // Be extra paranoid; avoid crashing.
  if (!dropData_.get()) {
    NOTREACHED() << "No drag-and-drop data available for promised file.";
    return nil;
  }

  FilePath fileName = downloadFileName_.empty() ?
      GetFileNameFromDragData(*dropData_) : downloadFileName_;
  FilePath filePath(SysNSStringToUTF8(path));
  filePath = filePath.Append(fileName);

  // CreateFileStreamForDrop() will call file_util::PathExists(),
  // which is blocking.  Since this operation is already blocking the
  // UI thread on OSX, it should be reasonable to let it happen.
  base::ThreadRestrictions::ScopedAllowIO allowIO;
  scoped_ptr<FileStream> fileStream(content::CreateFileStreamForDrop(
      &filePath, content::GetContentClient()->browser()->GetNetLog()));
  if (!fileStream.get())
    return nil;

  if (downloadURL_.is_valid()) {
    scoped_refptr<DragDownloadFile> dragFileDownloader(new DragDownloadFile(
        filePath,
        fileStream.Pass(),
        downloadURL_,
        content::Referrer(contents_->GetURL(), dropData_->referrer_policy),
        contents_->GetEncoding(),
        contents_));

    // The finalizer will take care of closing and deletion.
    dragFileDownloader->Start(new PromiseFileFinalizer(dragFileDownloader));
  } else {
    // The writer will take care of closing and deletion.
    BrowserThread::PostTask(BrowserThread::FILE,
                            FROM_HERE,
                            base::Bind(&PromiseWriterHelper,
                                       *dropData_,
                                       base::Passed(fileStream.Pass())));
  }

  // Once we've created the file, we should return the file name.
  return SysUTF8ToNSString(filePath.BaseName().value());
}

@end  // @implementation WebDragSource


@implementation WebDragSource (Private)

- (void)fillPasteboard {
  DCHECK(pasteboard_.get());

  [pasteboard_
      declareTypes:[NSArray arrayWithObject:ui::kChromeDragDummyPboardType]
             owner:contentsView_];

  // HTML.
  if (!dropData_->html.string().empty())
    [pasteboard_ addTypes:[NSArray arrayWithObject:NSHTMLPboardType]
                    owner:contentsView_];

  // URL (and title).
  if (dropData_->url.is_valid())
    [pasteboard_ addTypes:[NSArray arrayWithObjects:NSURLPboardType,
                                                    kNSURLTitlePboardType, nil]
                    owner:contentsView_];

  std::string fileExtension;

  // File.
  if (!dropData_->file_contents.empty() ||
      !dropData_->download_metadata.empty()) {
    if (dropData_->download_metadata.empty()) {
      fileExtension = GetFileNameFromDragData(*dropData_).Extension();
    } else {
      string16 mimeType;
      FilePath fileName;
      if (content::ParseDownloadMetadata(
              dropData_->download_metadata,
              &mimeType,
              &fileName,
              &downloadURL_)) {
        // Generate the file name based on both mime type and proposed file
        // name.
        std::string defaultName =
            content::GetContentClient()->browser()->GetDefaultDownloadName();
        downloadFileName_ =
            net::GenerateFileName(downloadURL_,
                                  std::string(),
                                  std::string(),
                                  fileName.value(),
                                  UTF16ToUTF8(mimeType),
                                  defaultName);
        fileExtension = downloadFileName_.Extension();
      }
    }

    if (!fileExtension.empty()) {
      // Strip the leading dot.
      fileExtension_ = SysUTF8ToNSString(fileExtension.substr(1));
      // File contents (with and without specific type), and file (HFS) promise.
      // TODO(viettrungluu): others?
      NSArray* types = [NSArray arrayWithObjects:
          NSFileContentsPboardType,
          NSCreateFileContentsPboardType(fileExtension_),
          NSFilesPromisePboardType,
          nil];
      [pasteboard_ addTypes:types owner:contentsView_];

      if (!dropData_->file_contents.empty()) {
        [pasteboard_ addTypes:[NSArray arrayWithObject:NSTIFFPboardType]
                        owner:contentsView_];
      }

      // For the file promise, we need to specify the extension.
      [pasteboard_ setPropertyList:[NSArray arrayWithObject:fileExtension_]
                           forType:NSFilesPromisePboardType];
    }
  }

  // Plain text.
  if (!dropData_->text.string().empty())
    [pasteboard_ addTypes:[NSArray arrayWithObject:NSStringPboardType]
                    owner:contentsView_];

  if (!dropData_->custom_data.empty()) {
    [pasteboard_
        addTypes:[NSArray arrayWithObject:ui::kWebCustomDataPboardType]
           owner:contentsView_];
  }
}

- (NSImage*)dragImage {
  if (dragImage_)
    return dragImage_;

  // Default to returning a generic image.
  return content::GetContentClient()->GetNativeImageNamed(
      IDR_DEFAULT_FAVICON).ToNSImage();
}

@end  // @implementation WebDragSource (Private)
