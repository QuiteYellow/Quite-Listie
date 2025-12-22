//
//  ExternalFilePresenter.swift
//  Listie-md
//
//  Created by Jack Nagy on 22/12/2025.
//


import Foundation

class ExternalFilePresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue.main
    
    private let onChange: () -> Void
    
    init(url: URL, onChange: @escaping () -> Void) {
        self.presentedItemURL = url
        self.onChange = onChange
        super.init()
        
        NSFileCoordinator.addFilePresenter(self)
    }
    
    deinit {
        NSFileCoordinator.removeFilePresenter(self)
    }
    
    func presentedItemDidChange() {
        print("📢 File changed: \(presentedItemURL?.lastPathComponent ?? "unknown")")
        onChange()
    }
    
    func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        print("🗑️ File deleted: \(presentedItemURL?.lastPathComponent ?? "unknown")")
        onChange()
        completionHandler(nil)
    }
}