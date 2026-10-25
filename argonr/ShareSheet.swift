//
//  ShareSheet.swift
//  argonr
//
//  SwiftUI's ShareLink takes one item; a generated asset is usually two — the
//  USD the viewer uses and the GLB other tools want — so this wraps the
//  system sheet to offer both at once.
//

import SwiftUI
import UIKit

struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
