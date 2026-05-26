import Foundation
import SwiftData

@MainActor
enum DataSeeder {
    static func seedIfNeeded(in modelContext: ModelContext) {
        let descriptor = FetchDescriptor<CRMContact>()
        let existingContacts = (try? modelContext.fetchCount(descriptor)) ?? 0
        guard existingContacts == 0 else { return }

        try? seedDemoData(in: modelContext)
    }

    static func resetDemoData(in modelContext: ModelContext) throws {
        for message in try modelContext.fetch(FetchDescriptor<ChatMessage>()) {
            modelContext.delete(message)
        }
        for thread in try modelContext.fetch(FetchDescriptor<ChatThread>()) {
            modelContext.delete(thread)
        }
        for todo in try modelContext.fetch(FetchDescriptor<TodoItem>()) {
            modelContext.delete(todo)
        }
        for contact in try modelContext.fetch(FetchDescriptor<CRMContact>()) {
            modelContext.delete(contact)
        }
        try modelContext.save()
        try seedDemoData(in: modelContext)
    }

    static func seedDemoData(in modelContext: ModelContext) throws {
        let calendar = Calendar.current
        let now = Date()
        let ada = CRMContact(
            name: "Ada Chen",
            company: "Northstar Labs",
            email: "ada@northstar.example",
            phone: "+1 555-0134",
            status: .active,
            dealValue: 48_000,
            dealStage: .proposal,
            lastContactedAt: calendar.date(byAdding: .day, value: -2, to: now),
            notes: "Prefers concise weekly updates and clear next steps."
        )
        let mason = CRMContact(
            name: "Mason Patel",
            company: "Forge Health",
            email: "mason@forge.example",
            phone: "+1 555-0188",
            status: .lead,
            dealValue: 22_500,
            dealStage: .qualified,
            lastContactedAt: calendar.date(byAdding: .day, value: -6, to: now),
            notes: "Asked for a short checklist before the next conversation."
        )
        let lena = CRMContact(
            name: "Lena Ortiz",
            company: "CivicGrid",
            email: "lena@civicgrid.example",
            phone: "+1 555-0161",
            status: .atRisk,
            dealValue: 16_000,
            dealStage: .prospect,
            lastContactedAt: calendar.date(byAdding: .day, value: -12, to: now),
            notes: "Needs a thoughtful follow-up after a quiet week."
        )

        [ada, mason, lena].forEach(modelContext.insert)

        let todos = [
            TodoItem(
                title: "Send Ada the rollout notes",
                notes: "Include milestones and the next check-in date.",
                priority: .high,
                dueDate: calendar.date(byAdding: .day, value: 1, to: now),
                contact: ada
            ),
            TodoItem(
                title: "Prepare security checklist",
                notes: "Map Mason's questions to SOC 2 and data retention policies.",
                priority: .medium,
                dueDate: calendar.date(byAdding: .day, value: 3, to: now),
                contact: mason
            ),
            TodoItem(
                title: "Archive closed Q1 notes",
                notes: "Keep only active relationship notes in the people list.",
                priority: .low,
                dueDate: calendar.date(byAdding: .day, value: -1, to: now),
                isCompleted: true,
                completedAt: calendar.date(byAdding: .hour, value: -6, to: now)
            )
        ]
        todos.forEach(modelContext.insert)

        let welcomeThread = ChatThread(title: "Planning assistant")
        modelContext.insert(welcomeThread)
        let intro = ChatMessage(
            body: "Ask me to turn a follow-up into a todo, summarize relationship context, or draft a next step.",
            sentAt: now,
            role: .assistant,
            thread: welcomeThread
        )
        modelContext.insert(intro)
        welcomeThread.messages.append(intro)

        try modelContext.save()
    }
}
