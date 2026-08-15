//
//  AsyncAssertions.swift
//  UnaMentisTests
//
//  Async-friendly wrappers around the XCTest assertions.
//
//  XCTest's assertions take a NON-async autoclosure, so `XCTAssertTrue(await
//  something())` fails to compile with "'async' call in an autoclosure that
//  does not support concurrency". Engine and host-service tests routinely need
//  to await a bounded condition (an actor read, a polled event log) inside an
//  assertion.
//
//  These wrappers take an already-resolved value in a normal argument position,
//  so the caller writes the await where it actually happens:
//
//      assertTrueAsync(await waitForEvents(in: log) { ... }, "message")
//
//  which keeps the assertion on one statement while reporting failures at the
//  caller's file and line.
//

import XCTest

/// `XCTAssertTrue` for a value produced by an awaited expression.
func assertTrueAsync(
    _ value: Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertTrue(value, message(), file: file, line: line)
}

/// `XCTAssertFalse` for a value produced by an awaited expression.
func assertFalseAsync(
    _ value: Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertFalse(value, message(), file: file, line: line)
}
