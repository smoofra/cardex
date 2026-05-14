//
//  ContentView.swift
//  cardex
//
//  Created by Lawrence D'Anna on 5/12/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var rfidService = RFIDReaderService()
    @State private var showingScanner = false
    @State private var scannedISBN: String? = nil
    @State private var bookTitle: String? = nil
    @State private var isFetchingTitle = false
    @State private var showingDOIScanner = false
    @State private var scannedDOI: String? = nil
    @State private var doiTitle: String? = nil
    @State private var isFetchingDOITitle = false
    @State private var scannedEPC: String? = nil
    @State private var saveError: String? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "book")
                    .imageScale(.large)
                    .foregroundStyle(.tint)
                Text("Scan an ISBN or DOI")
                    .font(.title2)

                if scannedISBN != nil || scannedDOI != nil || scannedEPC != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        if let isbn = scannedISBN {
                            Text("ISBN: \(isbn)")
                            if isFetchingTitle {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else if let title = bookTitle {
                                Text(title)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if let doi = scannedDOI {
                            Text("DOI: \(doi)")
                            if isFetchingDOITitle {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else if let title = doiTitle {
                                Text(title)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if let epc = scannedEPC {
                            Text("RFID: \(epc)")
                        }
                    }
                    .font(.body)
                    .monospaced()
                    .padding(.top, 8)
                }

                Button {
                    showingScanner = true
                } label: {
                    Label("Scan ISBN", systemImage: "barcode.viewfinder")
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(.tint, in: Capsule())
                        .foregroundStyle(.white)
                }
                .padding(.top, 12)

                Button {
                    showingDOIScanner = true
                } label: {
                    Label("Scan DOI", systemImage: "doc.text.viewfinder")
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(.tint, in: Capsule())
                        .foregroundStyle(.white)
                }

                NavigationLink(destination: RFIDInventoryView(onConfirm: { epc in
                    scannedEPC = epc
                }, service: rfidService)) {
                    Label("Scan RFID", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(.tint, in: Capsule())
                        .foregroundStyle(.white)
                }

                if let identifier = scannedISBN ?? scannedDOI, let epc = scannedEPC {
                    Button {
                        rfidService.clearTags()
                        save(identifier: identifier, epc: epc)
                    } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                            .font(.headline)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(.green, in: Capsule())
                            .foregroundStyle(.white)
                    }
                }

                if let error = saveError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .padding()
            .navigationTitle("cardex")
            .sheet(isPresented: $showingScanner) {
                NavigationStack {
                    ISBNScannerView { isbn in
                        scannedISBN = isbn
                        scannedDOI = nil
                        doiTitle = nil
                        bookTitle = nil
                        isFetchingTitle = true
                        Task {
                            bookTitle = await lookupISBNTitle(isbn: isbn)
                            isFetchingTitle = false
                        }
                    }
                }
            }
            .sheet(isPresented: $showingDOIScanner) {
                NavigationStack {
                    DOIScannerView { doi in
                        scannedDOI = doi
                        scannedISBN = nil
                        bookTitle = nil
                        doiTitle = nil
                        isFetchingDOITitle = true
                        Task {
                            doiTitle = await lookupDOITitle(doi: doi)
                            isFetchingDOITitle = false
                        }
                    }
                }
            }
        }
    }

    private func lookupISBNTitle(isbn: String) async -> String? {
        guard let url = URL(string: "https://openlibrary.org/isbn/\(isbn).json") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        struct Book: Decodable { let title: String }
        return (try? JSONDecoder().decode(Book.self, from: data))?.title
    }

    private func lookupDOITitle(doi: String) async -> String? {
        let prefix = doi.components(separatedBy: "/").first ?? ""
        guard let raURL = URL(string: "https://doi.org/ra/\(prefix)"),
              let (raData, _) = try? await URLSession.shared.data(from: raURL),
              let raArray = try? JSONDecoder().decode([[String: String]].self, from: raData),
              let ra = raArray.first?["RA"]
        else { return nil }

        switch ra {
        case "Crossref":
            return await lookupCrossrefTitle(doi: doi)
        case "DataCite":
            return await lookupDataCiteTitle(doi: doi)
        default:
            return nil
        }
    }

    private func lookupCrossrefTitle(doi: String) async -> String? {
        let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi
        guard let url = URL(string: "https://api.crossref.org/works/\(encoded)") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        struct Response: Decodable {
            struct Message: Decodable { let title: [String] }
            let message: Message
        }
        return (try? JSONDecoder().decode(Response.self, from: data))?.message.title.first
    }

    private func lookupDataCiteTitle(doi: String) async -> String? {
        let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi
        guard let url = URL(string: "https://api.datacite.org/dois/\(encoded)") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        struct Response: Decodable {
            struct Data: Decodable {
                struct Attributes: Decodable {
                    struct Title: Decodable { let title: String }
                    let titles: [Title]
                }
                let attributes: Attributes
            }
            let data: Data
        }
        return (try? JSONDecoder().decode(Response.self, from: data))?.data.attributes.titles.first?.title
    }

    private func save(identifier: String, epc: String) {
        let line = "\"\(identifier)\",\"\(epc)\"\n"
        let fileName = "cardex.csv"

        let dir: URL
        if let icloud = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
            dir = icloud.appendingPathComponent("Documents", isDirectory: true)
        } else {
            dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        }

        let fileURL = dir.appendingPathComponent(fileName)

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                handle.write(Data(line.utf8))
                try handle.close()
            } else {
                let header = "\"identifier\",\"epc\"\n"
                try (header + line).write(to: fileURL, atomically: true, encoding: .utf8)
            }
            scannedISBN = nil
            bookTitle = nil
            scannedDOI = nil
            doiTitle = nil
            scannedEPC = nil
            saveError = nil
        } catch {
            saveError = "Save failed: \(error.localizedDescription)"
        }
    }
}

#Preview {
    ContentView()
}
