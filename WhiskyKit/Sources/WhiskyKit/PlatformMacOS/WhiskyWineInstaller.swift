//
//  WhiskyWineInstaller.swift
//  WhiskyKit
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import Foundation
import SemanticVersion

public class WhiskyWineInstaller {
    /// The Whisky application folder
    public static let applicationFolder = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    )[0].appending(path: Bundle.whiskyBundleIdentifier)

    /// The folder of all the libfrary files
    public static let libraryFolder = applicationFolder.appending(path: "Libraries")

    /// URL to the installed `wine` `bin` directory
    public static let binFolder: URL = libraryFolder.appending(path: "Wine").appending(path: "bin")

    /// Where the KosmicKrisp (Mesa) driver keeps its compiled shaders.
    ///
    /// Mesa derives its own default from `XDG_CACHE_HOME`/`HOME`, and under
    /// Wine that never produced a cache directory at all — so every launch
    /// recompiled every pipeline from scratch. Pointing it somewhere stable
    /// turns a per-launch compile storm into a one-time cost per pipeline,
    /// which matters most for the legacy fixed-function paths (DirectDraw,
    /// D3D8) that replay hundreds of pipelines at once.
    public static let shaderCacheFolder = applicationFolder.appending(path: "ShaderCache")

    /// `shaderCacheFolder`, created if missing. Returns nil when it cannot be
    /// created, so a caller can leave the variable unset rather than point the
    /// driver at a path it will fail to write.
    public static func ensureShaderCacheFolder() -> URL? {
        do {
            try FileManager.default.createDirectory(
                at: shaderCacheFolder, withIntermediateDirectories: true
            )
            return shaderCacheFolder
        } catch {
            return nil
        }
    }

    public static func isWhiskyWineInstalled() -> Bool {
        return whiskyWineVersion() != nil
    }

    public static func whiskyWineVersion() -> SemanticVersion? {
        do {
            let versionPlist =
                libraryFolder
                .appending(path: "WhiskyWineVersion")
                .appendingPathExtension("plist")

            let decoder = PropertyListDecoder()
            let data = try Data(contentsOf: versionPlist)
            let info = try decoder.decode(WhiskyWineVersion.self, from: data)
            return info.version
        } catch {
            print(error)
            return nil
        }
    }
}

public struct WhiskyWineVersion: Codable {
    public var version = SemanticVersion(1, 0, 0)
}
