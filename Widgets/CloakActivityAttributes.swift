// The Live Activity's attributes and content state live in CloakKit, at
// Shared/DriveActivity.swift, because the app, the widget extension and the
// tests all need the same type. A copy compiled into this target would be a
// different type with the same name, and ActivityKit would fail to match the
// activity the app started with the presentation the widget draws.
//
// This file is kept, empty, only so the target's file list does not change.
