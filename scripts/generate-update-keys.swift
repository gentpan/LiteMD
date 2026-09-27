#!/usr/bin/env swift
// 生成应用更新使用的 Ed25519 密钥对。
//
// 用法：swift scripts/generate-update-keys.swift <私钥输出路径>
// 私钥只保存在发布者本机（权限 600），不要提交到仓库；公钥写入 LITEMD_UPDATE_PUBLIC_KEY。
import CryptoKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift scripts/generate-update-keys.swift <private-key-file>\n".utf8))
    exit(64)
}
let path = CommandLine.arguments[1]
guard !FileManager.default.fileExists(atPath: path) else {
    FileHandle.standardError.write(Data("refusing to overwrite existing key: \(path)\n".utf8))
    exit(73)
}
let key = Curve25519.Signing.PrivateKey()
// 写不进去时不能打印公钥：否则发布者会按一个没有对应私钥的公钥配置应用。
guard FileManager.default.createFile(atPath: path, contents: Data(key.rawRepresentation.base64EncodedString().utf8), attributes: [.posixPermissions: 0o600]) else {
    FileHandle.standardError.write(Data("could not write private key: \(path)\n".utf8))
    exit(73)
}
print("Private key written to \(path)")
print("Public key (LITEMD_UPDATE_PUBLIC_KEY):")
print(key.publicKey.rawRepresentation.base64EncodedString())
