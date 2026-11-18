import Foundation
import Security
import Testing
@testable import NeSpatPrivilegeCore

@Suite struct SigningPolicyContractTests {
    @Test func strictRequirementIncludesEveryConjunctAndSeparatesTeamsAndIdentifiers() throws {
        let a=try SigningPolicy(teamID:"ABCDE12345"), b=try SigningPolicy(teamID:"ZYXWV98765")
        #expect(a.guiRequirement != a.helperRequirement && a.guiRequirement != b.guiRequirement)
        for (requirement,id) in [(a.guiRequirement,SigningPolicy.guiIdentifier),(a.helperRequirement,SigningPolicy.helperIdentifier)] {
            for clause in ["anchor apple generic","certificate 1[field.1.2.840.113635.100.6.2.6] exists",
                "certificate leaf[field.1.2.840.113635.100.6.1.13] exists","certificate leaf[subject.OU] = \"ABCDE12345\"",
                "identifier \"\(id)\""] {#expect(requirement.contains(clause))}
            #expect(!requirement.contains(" or "))
            var parsed: SecRequirement?
            #expect(SecRequirementCreateWithString(requirement as CFString,[],&parsed) == errSecSuccess)
        }
        // This checks policy/compiler structure, NOT real same-Team/other-ID acceptance.
    }
    @Test func malformedRequirementCompilerAndTeamInjectionFailWithoutCallingFatalXPCAPI() throws {
        for text in ["(","identifier", "certificate leaf[bad", "anchor apple and ("] {
            var requirement: SecRequirement?
            #expect(SecRequirementCreateWithString(text as CFString,[],&requirement) != errSecSuccess)
        }
        for team in ["", "ABCDE12345\" or true", "abcdefghij", "ABCDE1234\n"] {
            #expect(throws:PrivilegeError.blocked) {try SigningPolicy(teamID:team)}
        }
    }
    @Test func replacedUntrustedFileCannotSatisfyHelperPolicy() throws {
        let repo=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir=repo.appendingPathComponent(".build/v75-signing/\(UUID())")
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:dir)}
        let file=dir.appendingPathComponent("untrusted"), policy=try SigningPolicy(teamID:"ABCDE12345")
        try Data("unsigned; never executed".utf8).write(to:file)
        #expect(!policy.matchesFile(file,helper:true))
        try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[0])).write(to:file)
        #expect(!policy.matchesFile(file,helper:true)) // Current ad-hoc test executable.
        try Data("replaced; never executed".utf8).write(to:file)
        #expect(!policy.matchesFile(file,helper:true))
        // No signing, certificate use, installed-binary replacement or trusted-positive claim.
    }
}
