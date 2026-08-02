//
//  AutoEQRedirectGuardTests.swift
//  SherlockEQTests
//
//  Redirect host-pinning for AutoEQ fetches (audit N-3). Exercises the host /
//  scheme decision directly — the delegate method just forwards to it.
//

import Testing
import Foundation
@testable import SherlockEQ

struct AutoEQRedirectGuardTests {

    private func allowed(_ string: String) -> Bool {
        AutoEQRedirectGuard.isAllowedRedirect(URL(string: string))
    }

    // MARK: - Allowed: GitHub content family over HTTPS

    @Test func allowsRawGithubUserContentOverHTTPS() {
        #expect(allowed("https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/README.md"))
    }

    @Test func allowsGithubCDNAssetHost() {
        // GitHub's own redirect target for larger assets.
        #expect(allowed("https://objects.githubusercontent.com/some/object"))
    }

    @Test func allowsApexGithubUserContent() {
        #expect(allowed("https://githubusercontent.com/x"))
    }

    // MARK: - Rejected

    @Test func rejectsForeignHost() {
        #expect(!allowed("https://evil.com/results/ParametricEQ.txt"))
    }

    @Test func rejectsLookalikeHostWithoutDotBoundary() {
        // No dot before "githubusercontent" — must not be treated as a subdomain.
        #expect(!allowed("https://evilgithubusercontent.com/x"))
    }

    @Test func rejectsHTTPSchemeDowngrade() {
        #expect(!allowed("http://raw.githubusercontent.com/x"))
    }

    @Test func rejectsHostAsUserinfoTrick() {
        // Real host is evil.com; githubusercontent.com is only userinfo.
        #expect(!allowed("https://raw.githubusercontent.com@evil.com/x"))
    }

    @Test func rejectsNilAndMalformed() {
        #expect(!AutoEQRedirectGuard.isAllowedRedirect(nil))
        #expect(!allowed("not a url with spaces"))
    }
}
