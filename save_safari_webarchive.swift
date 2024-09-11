#!/usr/bin/env swift
import Foundation

let SCRIPT_VERSION = "5.2.5"

// MARK: - Utility Functions

func runAppleScript(_ script: String) -> String? {
    let process = Process()
    process.launchPath = "/usr/bin/osascript"
    process.arguments = ["-e", script]
    
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    process.launch()
    
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    
    if process.terminationStatus != 0 {
        if let error = String(data: data, encoding: .utf8) {
            fputs("AppleScript error: \(error)", stderr)
        }
        return nil
    }
    
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Web Interaction

func getAuthenticatedContent(url: String, retries: Int = 3) -> String? {
    for attempt in 1...retries {
        let script = """
        tell application "Safari"
            set currentTab to current tab of front window
            set currentURL to URL of currentTab
            set URL of currentTab to "\(url)"
            delay 5 -- Wait for page to load
            -- Capture page content
            try
                set pageContent to do JavaScript "document.documentElement.outerHTML" in currentTab
                -- Return to original URL
                set URL of currentTab to currentURL
                return pageContent
            on error errMsg
                log "Error on attempt \(attempt): " & errMsg
                delay 2 -- Wait before retry
            end try
        end tell
        """
        
        if let result = runAppleScript(script) {
            return result
        }
        
        print("Attempt \(attempt) failed. Retrying...")
    }
    
    print("Failed to retrieve content after \(retries) attempts.")
    return nil
}

// MARK: - File Operations

func saveWebArchive(content: String, url: String, savePath: String) -> Bool {
    let webArchiveContent = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>WebMainResource</key>
        <dict>
            <key>WebResourceData</key>
            <data>
            \(Data(content.utf8).base64EncodedString())
            </data>
            <key>WebResourceFrameName</key>
            <string></string>
            <key>WebResourceMIMEType</key>
            <string>text/html</string>
            <key>WebResourceTextEncodingName</key>
            <string>UTF-8</string>
            <key>WebResourceURL</key>
            <string>\(url)</string>
        </dict>
    </dict>
    </plist>
    """
    
    do {
        try webArchiveContent.write(to: URL(fileURLWithPath: savePath), atomically: true, encoding: .utf8)
        return true
    } catch {
        print("Failed to save WebArchive: \(error)")
        return false
    }
}

func saveHTML(content: String, savePath: String) -> Bool {
    do {
        try content.write(to: URL(fileURLWithPath: savePath), atomically: true, encoding: .utf8)
        return true
    } catch {
        print("Failed to save HTML: \(error)")
        return false
    }
}

// MARK: - Crawler

class Crawler {
    let baseURL: String
    let outputDir: String
    var visitedURLs = Set<String>()
    var urlsToVisit = [String]()
    let delay: TimeInterval
    
    init(baseURL: String, outputDir: String, delay: TimeInterval) {
        self.baseURL = baseURL
        self.outputDir = outputDir
        self.delay = delay
        self.urlsToVisit.append(baseURL)
    }
    
    func crawl() {
        while !urlsToVisit.isEmpty {
            let url = urlsToVisit.removeFirst()
            let normalizedURL = normalizeURL(url)
            if !visitedURLs.contains(normalizedURL) && normalizedURL.starts(with: baseURL) {
                visitedURLs.insert(normalizedURL)
                
                print("Crawling: \(normalizedURL)")
                
                if let content = getAuthenticatedContent(url: normalizedURL) {
                    let (webArchivePath, htmlPath) = generatePaths(for: normalizedURL)
                    
                    if saveWebArchive(content: content, url: normalizedURL, savePath: webArchivePath) {
                        print("Saved WebArchive: \(webArchivePath)")
                    } else {
                        print("Failed to save WebArchive: \(normalizedURL)")
                    }
                    
                    if saveHTML(content: content, savePath: htmlPath) {
                        print("Saved HTML: \(htmlPath)")
                    } else {
                        print("Failed to save HTML: \(normalizedURL)")
                    }
                    
                    // Extract and add new URLs to visit
                    let newURLs = extractLinksFromBody(from: content, baseURL: baseURL, currentURL: normalizedURL)
                    let filteredNewURLs = newURLs.filter { !visitedURLs.contains($0) }
                    urlsToVisit.append(contentsOf: filteredNewURLs)
                    print("Added \(filteredNewURLs.count) new URLs to visit")
                } else {
                    print("Failed to retrieve content for: \(normalizedURL)")
                }
                
                Thread.sleep(forTimeInterval: delay)
            }
        }
    }
    
    func normalizeURL(_ url: String) -> String {
        guard var components = URLComponents(string: url) else { return url }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        
        // Remove duplicate domains
        if let host = components.host, components.path.starts(with: "/\(host)") {
            components.path = String(components.path.dropFirst(host.count + 1))
        }
        
        // Remove duplicate paths
        let pathComponents = components.path.components(separatedBy: "/").filter { !$0.isEmpty }
        components.path = "/" + pathComponents.joined(separator: "/")
        
        // Remove fragment
        components.fragment = nil
        
        return components.string ?? url
    }
    
    func generatePaths(for url: String) -> (String, String) {
        let urlComponents = URLComponents(string: url)
        let pathComponents = urlComponents?.path.components(separatedBy: "/").filter { !$0.isEmpty }
        let filename = pathComponents?.last ?? "index"
        
        let relativePath = url.replacingOccurrences(of: baseURL, with: "")
        let dirPath = (outputDir as NSString).appendingPathComponent(relativePath)
        
        do {
            try FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("Failed to create directory: \(error)")
        }
        
        let webArchivePath = (dirPath as NSString).appendingPathComponent("\(filename).webarchive")
        let htmlPath = (dirPath as NSString).appendingPathComponent("\(filename).html")
        
        return (webArchivePath, htmlPath)
    }
    
    func extractLinksFromBody(from content: String, baseURL: String, currentURL: String) -> [String] {
        let bodyPattern = "<body[^>]*>(.*?)</body>"
        let bodyRegex = try! NSRegularExpression(pattern: bodyPattern, options: [.dotMatchesLineSeparators])
        let nsString = content as NSString
        let bodyRange = bodyRegex.firstMatch(in: content, options: [], range: NSRange(location: 0, length: nsString.length))?.range(at: 1)
        
        guard let bodyContent = bodyRange.map({ nsString.substring(with: $0) }) else {
            return []
        }
        
        let linkPattern = "href=['\"]([^'\"]+)['\"]"
        let linkRegex = try! NSRegularExpression(pattern: linkPattern, options: [])
        let results = linkRegex.matches(in: bodyContent, options: [], range: NSRange(location: 0, length: bodyContent.count))
        
        return results.compactMap { result -> String? in
            let match = (bodyContent as NSString).substring(with: result.range(at: 1))
            
            // Skip links that are references to headers in the same page
            if URL(string: match)?.fragment != nil {
                return nil
            }
            
            let normalizedMatch = normalizeURL(match)
            if normalizedMatch.starts(with: baseURL) {
                // Check if the normalized match is the same as the current URL (excluding fragments)
                let currentURLWithoutFragment = normalizeURL(currentURL)
                if normalizedMatch == currentURLWithoutFragment {
                    return nil
                }
                return normalizedMatch
            } else if normalizedMatch.starts(with: "/") {
                return normalizeURL(baseURL + normalizedMatch)
            }
            return nil
        }
    }
}

// MARK: - Main

if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--version" {
    let filename = (CommandLine.arguments[0] as NSString).lastPathComponent
    print("\(filename) \(SCRIPT_VERSION)")
    exit(0)
}

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: \(CommandLine.arguments[0]) <BASE_URL> <OUTPUT_DIR>\n", stderr)
    exit(1)
}

let baseURL = CommandLine.arguments[1]
let outputDir = CommandLine.arguments[2]

// Create output directory if it doesn't exist
do {
    try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true, attributes: nil)
} catch {
    print("Failed to create output directory: \(error)")
    exit(1)
}

let crawler = Crawler(baseURL: baseURL, outputDir: outputDir, delay: 5.0) // 5 second delay between requests
crawler.crawl()

print("Crawling completed.")