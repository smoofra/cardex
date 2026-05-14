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
                    ISBNScannerView { code in
                        scannedISBN = code
                    }
                }
            }
        }
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
