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
    @State private var scannedEPC: String? = nil
    @State private var saveError: String? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "book")
                    .imageScale(.large)
                    .foregroundStyle(.tint)
                Text("Scan an ISBN")
                    .font(.title2)

                if scannedISBN != nil || scannedEPC != nil {
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

                if let isbn = scannedISBN, let epc = scannedEPC {
                    Button {
                        rfidService.clearTags()
                        save(isbn: isbn, epc: epc)
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
                        bookTitle = nil
                        isFetchingTitle = true
                        Task {
                            bookTitle = await lookupTitle(isbn: isbn)
                            isFetchingTitle = false
                        }
                    }
                }
            }
        }
    }

    private func lookupTitle(isbn: String) async -> String? {
        guard let url = URL(string: "https://openlibrary.org/isbn/\(isbn).json") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        struct Book: Decodable { let title: String }
        return (try? JSONDecoder().decode(Book.self, from: data))?.title
    }

    private func save(isbn: String, epc: String) {
        let line = "\"\(isbn)\",\"\(epc)\"\n"
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
                let header = "\"isbn\",\"epc\"\n"
                try (header + line).write(to: fileURL, atomically: true, encoding: .utf8)
            }
            scannedISBN = nil
            bookTitle = nil
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
