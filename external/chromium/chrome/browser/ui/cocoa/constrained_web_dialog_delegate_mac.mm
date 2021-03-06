// Copyright (c) 2012 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "chrome/browser/ui/webui/constrained_web_dialog_delegate_base.h"

#import <Cocoa/Cocoa.h>

#include "base/memory/scoped_nsobject.h"
#import "chrome/browser/ui/cocoa/constrained_window/constrained_window_custom_sheet.h"
#import "chrome/browser/ui/cocoa/constrained_window/constrained_window_custom_window.h"
#import "chrome/browser/ui/cocoa/constrained_window/constrained_window_mac.h"
#include "content/public/browser/web_contents.h"
#include "ui/gfx/size.h"
#include "ui/web_dialogs/web_dialog_delegate.h"
#include "ui/web_dialogs/web_dialog_ui.h"
#include "ui/web_dialogs/web_dialog_web_contents_delegate.h"

using content::WebContents;
using ui::WebDialogDelegate;
using ui::WebDialogWebContentsDelegate;

class ConstrainedWebDialogDelegateMac :
    public ConstrainedWindowMacDelegate,
    public ConstrainedWebDialogDelegate {

 public:
  ConstrainedWebDialogDelegateMac(
      content::BrowserContext* browser_context,
      WebDialogDelegate* delegate,
      WebDialogWebContentsDelegate* tab_delegate,
      content::WebContents* web_contents);
  virtual ~ConstrainedWebDialogDelegateMac() {}

  // ConstrainedWebDialogDelegate interface
  virtual const WebDialogDelegate*
      GetWebDialogDelegate() const OVERRIDE {
    return impl_->GetWebDialogDelegate();
  }
  virtual WebDialogDelegate* GetWebDialogDelegate() OVERRIDE {
    return impl_->GetWebDialogDelegate();
  }
  virtual void OnDialogCloseFromWebUI() OVERRIDE {
    return impl_->OnDialogCloseFromWebUI();
  }
  virtual void ReleaseWebContentsOnDialogClose() OVERRIDE {
    return impl_->ReleaseWebContentsOnDialogClose();
  }
  virtual ConstrainedWindow* GetWindow() OVERRIDE {
    return impl_->GetWindow();
  }
  virtual WebContents* GetWebContents() OVERRIDE {
    return impl_->GetWebContents();
  }

  // ConstrainedWindowMacDelegate interface
  virtual void OnConstrainedWindowClosed(
      ConstrainedWindowMac* window) OVERRIDE {
    if (!impl_->closed_via_webui())
      GetWebDialogDelegate()->OnDialogClosed("");
    delete this;
  }

 private:
  scoped_ptr<ConstrainedWebDialogDelegateBase> impl_;
  scoped_ptr<ConstrainedWindowMac> constrained_window_;
  scoped_nsobject<NSWindow> window_;

  DISALLOW_COPY_AND_ASSIGN(ConstrainedWebDialogDelegateMac);
};

ConstrainedWebDialogDelegateMac::ConstrainedWebDialogDelegateMac(
    content::BrowserContext* browser_context,
    WebDialogDelegate* delegate,
    WebDialogWebContentsDelegate* tab_delegate,
    content::WebContents* web_contents)
    : impl_(new ConstrainedWebDialogDelegateBase(browser_context,
                                                 delegate,
                                                 tab_delegate)) {
  // Create a window to hold web_contents in the constrained sheet:
  gfx::Size size;
  delegate->GetDialogSize(&size);
  NSRect frame = NSMakeRect(0, 0, size.width(), size.height());

  window_.reset(
      [[ConstrainedWindowCustomWindow alloc] initWithContentRect:frame]);
  [GetWebContents()->GetNativeView() setFrame:frame];
  [[window_ contentView] addSubview:GetWebContents()->GetNativeView()];

  scoped_nsobject<CustomConstrainedWindowSheet> sheet(
      [[CustomConstrainedWindowSheet alloc]
          initWithCustomWindow:window_]);
  constrained_window_.reset(new ConstrainedWindowMac(
      this, web_contents, sheet));
  return impl_->set_window(constrained_window_.get());
}

ConstrainedWebDialogDelegate* CreateConstrainedWebDialog(
        content::BrowserContext* browser_context,
        WebDialogDelegate* delegate,
        WebDialogWebContentsDelegate* tab_delegate,
        content::WebContents* web_contents) {
  // Deleted when the dialog closes.
  ConstrainedWebDialogDelegateMac* constrained_delegate =
      new ConstrainedWebDialogDelegateMac(
          browser_context, delegate, tab_delegate, web_contents);
  return constrained_delegate;
}
