//
//  ShareViewController.swift
//  ShareExtension
//
//  Forwards shared content to the host app via the share_handler plugin.
//  The base class handles serialization into the App Group container and
//  deep-links back to the host app via the ShareMedia-<bundleId> URL scheme.
//

import share_handler_ios_models

class ShareViewController: ShareHandlerIosViewController {}
