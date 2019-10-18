//
// BaseChatViewControllerWithShare.swift
//
// Siskin IM
// Copyright (C) 2017 "Tigase, Inc." <office@tigase.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. Look for COPYING file in the top folder.
// If not, see https://www.gnu.org/licenses/.
//

import UIKit
import MobileCoreServices
import TigaseSwift

protocol BaseChatViewController_ShareImageExtension: class {
    
    var progressBar: UIProgressView! { get set }
    var shareButton: UIButton! { get set }
    
    var imagePickerDelegate: BaseChatViewController_ShareImagePickerDelegate? { get set }
    var filePickerDelegate: BaseChatViewController_ShareFilePickerDelegate? { get set }
    
    var xmppService: XmppService! { get }
    var account: BareJID! { get }
    var jid: BareJID! { get }
    
    
    func sendMessage(body: String, url: String?, preview: String?, completed: (()->Void)?);
    
    func present(_ controller: UIViewController, animated: Bool, completion: (()->Void)?);
}

extension BaseChatViewController_ShareImageExtension {
    
    func initSharing() {
        shareButton.isEnabled = Settings.SharingViaHttpUpload.getBool();
    }
    
    func showPhotoSelector(_ sender: UIView) {
        let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet);
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            alert.addAction(UIAlertAction(title: "Take photo", style: .default, handler: { (action) in
                self.selectPhoto(.camera);
            }));
        }
        alert.addAction(UIAlertAction(title: "Select photo", style: .default, handler: { (action) in
            self.selectPhoto(.photoLibrary);
        }));
        alert.addAction(UIAlertAction(title: "Select file", style: .default, handler: { (action) in
            self.selectFile();
        }));
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil));
        alert.popoverPresentationController?.sourceView = sender;
        alert.popoverPresentationController?.sourceRect = sender.bounds;
        present(alert, animated: true, completion: nil);
    }
    
    func selectPhoto(_ source: UIImagePickerController.SourceType) {
        let picker = UIImagePickerController();
        self.imagePickerDelegate = BaseChatViewController_ShareImagePickerDelegate(self);
        picker.delegate = self.imagePickerDelegate;
        picker.allowsEditing = false;//true;
        picker.sourceType = source;
        present(picker, animated: true, completion: nil);
    }

    func selectFile() {
        let picker = UIDocumentPickerViewController(documentTypes: [String(kUTTypeData)], in: .open);
        self.filePickerDelegate = BaseChatViewController_ShareFilePickerDelegate(self);
        picker.delegate = self.filePickerDelegate;
        picker.allowsMultipleSelection = false;
        self.present(picker, animated: true, completion: nil);
    }
    
}

enum ShareError: Error {
    case unknownError
    case noAccessError
    case noFileSizeError
    case noMimeTypeError
    
    case notSupported
    case fileTooBig
    
    case httpError
    
    var message: String {
        switch self {
        case .unknownError:
            return "Please try again later."
        case .noAccessError:
            return "It was not possible to access the file."
        case .noFileSizeError:
            return "Could not retrieve file size.";
        case .noMimeTypeError:
            return "Could not detect MIME type of a file.";
        case .notSupported:
            return "Feature not supported by XMPP server";
        case .fileTooBig:
            return "File is too big to share";
        case .httpError:
            return "Upload to HTTP server failed.";
        }
    }
}

class BaseChatViewController_SharePickerDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
 
    let controller: BaseChatViewController_ShareImageExtension;
    
    init(_ controller: BaseChatViewController_ShareImageExtension) {
        self.controller = controller;
    }

    func share(filename: String, url: URL, completionHandler: @escaping (Result<URL,ShareError>)->Void) {
        guard url.startAccessingSecurityScopedResource() else {
            completionHandler(.failure(.noAccessError));
            return;
        }
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .typeIdentifierKey]), let size = values.fileSize else {
            url.stopAccessingSecurityScopedResource();
            completionHandler(.failure(.noFileSizeError));
            return;
        }
        
        var mimeType: String = "application/octet-stream";
        
        if let type = values.typeIdentifier, let mimeTypeRef = UTTypeCopyPreferredTagWithClass(type as CFString, kUTTagClassMIMEType) {
            mimeType = mimeTypeRef.takeUnretainedValue() as String;
            mimeTypeRef.release();
        }
        
        guard let inputStream = InputStream(url: url) else {
            url.stopAccessingSecurityScopedResource();
            completionHandler(.failure(.noAccessError));
            return;
        }
        self.share(filename: filename, inputStream: inputStream, filesize: size, mimeType: mimeType, completionHandler: { result in
            url.stopAccessingSecurityScopedResource();
            switch result {
            case .success(let getUri):
                completionHandler(.success(getUri));
            case .failure(let error):
                completionHandler(.failure(error));
            }
        });
    }
    
    func share(filename: String, inputStream: InputStream, filesize size: Int, mimeType: String, completionHandler: @escaping (Result<URL,ShareError>)->Void) {
        if let client = self.controller.xmppService.getClient(forJid: self.controller.account) {
            let httpUploadModule: HttpFileUploadModule = client.modulesManager.getModule(HttpFileUploadModule.ID)!;
            httpUploadModule.findHttpUploadComponent(onSuccess: { (results) in
                var compJid: JID? = nil;
                results.forEach({ (k,v) in
                    if compJid != nil {
                        return;
                    }
                    if v != nil && v! < size {
                        return;
                    }
                    compJid = k;
                });

                guard compJid != nil else {
                    guard results.count > 0 else {
                        completionHandler(.failure(.notSupported));
                        return;
                    }
                    completionHandler(.failure(.fileTooBig));
                    return;
                }
            
                httpUploadModule.requestUploadSlot(componentJid: compJid!, filename: filename, size: size, contentType: mimeType, onSuccess: { (slot) in
                    DispatchQueue.main.async {
                        self.controller.progressBar.isHidden = false;
                    }
                    var request = URLRequest(url: slot.putUri);
                    slot.putHeaders.forEach({ (k,v) in
                        request.addValue(v, forHTTPHeaderField: k);
                    });
                    request.httpMethod = "PUT";
                    request.httpBodyStream = inputStream;
                    request.addValue(String(size), forHTTPHeaderField: "Content-Lenght");
                    request.addValue(mimeType, forHTTPHeaderField: "Content-Type");
                    let session = URLSession(configuration: URLSessionConfiguration.default, delegate: self, delegateQueue: OperationQueue.main);
                    session.dataTask(with: request) { (data, response, error) in
                        guard error == nil && ((response as? HTTPURLResponse)?.statusCode ?? 500) == 201 else {
                            completionHandler(.failure(.httpError));
                            return;
                        }
                        completionHandler(.success(slot.getUri));
                        }.resume();
                }, onError: { (error, message) in
                    completionHandler(.failure(.unknownError));
                })
            }, onError: { (error) in
                if error != nil && error! == ErrorCondition.item_not_found {
                    completionHandler(.failure(.notSupported));
                } else {
                    completionHandler(.failure(.unknownError));
                }
            })
        }
    }
    
    func showAlert(shareError: ShareError) {
        self.showAlert(title: "Upload failed", message: shareError.message);
    }
    
    func showAlert(title: String, message: String) {
        DispatchQueue.main.async {
            self.controller.progressBar.isHidden = false;
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert);
            alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil));
            self.controller.present(alert, animated: true, completion: nil);
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        self.controller.progressBar.progress = Float(totalBytesSent) / Float(totalBytesExpectedToSend);
        if self.controller.progressBar.progress == 1.0 {
            self.controller.progressBar.isHidden = true;
            self.controller.progressBar.progress = 0;
        }
    }
}

class BaseChatViewController_ShareFilePickerDelegate: BaseChatViewController_SharePickerDelegate, UIDocumentPickerDelegate {
    
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else {
            return;
        }
        print("url:", url);
        controller.dismiss(animated: true, completion: nil);
        self.controller.filePickerDelegate = nil;
            
        share(filename: url.lastPathComponent, url: url) { (result) in
            switch result {
            case .success(let getUri):
                print("file uploaded to:", getUri);
                self.controller.sendMessage(body: getUri.absoluteString, url: getUri.absoluteString, preview: nil, completed: nil);
            case .failure(let error):
                self.showAlert(shareError: error);
            }
        }
    }
    
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        self.controller.filePickerDelegate = nil;
        controller.dismiss(animated: true, completion: nil);
    }
    
}

class BaseChatViewController_ShareImagePickerDelegate: BaseChatViewController_SharePickerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    
    @objc func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        controller.imagePickerDelegate = nil;
        picker.dismiss(animated: true, completion: nil);
    }
    
    @objc func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        
        guard let photo = (info[UIImagePickerController.InfoKey.editedImage] as? UIImage) ?? (info[UIImagePickerController.InfoKey.originalImage] as? UIImage) else {
            return;
        }
        print("photo", photo.size, "originalImage", info[UIImagePickerController.InfoKey.originalImage] as Any);
        let imageName = "image.jpg";
        
        // saving photo
        let data = photo.jpegData(compressionQuality: 0.9);
        picker.dismiss(animated: true, completion: nil);
        if data != nil {
            self.share(filename: "image.jpg", inputStream: InputStream(data: data!), filesize: data!.count, mimeType: "image/jpeg") { (result) in
                switch result {
                case .success(let getUri):
                    print("file uploaded to:", getUri);
                    ImageCache.shared.set(image: photo) { (key) in
                        self.controller.sendMessage(body: getUri.absoluteString, url: getUri.absoluteString, preview: "preview:image:\(key)", completed: nil);
                    }
                case .failure(let error):
                    self.showAlert(shareError: error);
                }
            }
        }
        controller.imagePickerDelegate = nil;
    }
    
}

// Helper function inserted by Swift 4.2 migrator.
fileprivate func convertFromUIImagePickerControllerInfoKey(_ input: UIImagePickerController.InfoKey) -> String {
	return input.rawValue
}