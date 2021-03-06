// Copyright 2012 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "cc/layer_updater.h"

namespace cc {

LayerUpdater::Resource::Resource(scoped_ptr<PrioritizedResource> texture)
    : m_texture(texture.Pass())
{
}

LayerUpdater::Resource::~Resource()
{
}

}  // namespace cc
