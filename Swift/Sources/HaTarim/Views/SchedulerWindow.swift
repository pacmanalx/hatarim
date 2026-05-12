import SwiftUI
import AppKit

/// Janela dedicada do Scheduler — lista + editor inline.
struct SchedulerWindow: View {
    @ObservedObject var store: TasksStore
    @ObservedObject var scheduler: TaskScheduler
    @State private var selection: UUID? = nil
    @State private var capturing: Bool = false
    @State private var captureCountdown: Int = 0

    var body: some View {
        HSplitView {
            // Lista
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.config.tasks) { t in
                        HStack(spacing: 8) {
                            Toggle("", isOn: bindingEnabled(for: t.id))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                            Image(systemName: t.actionKind.systemImage)
                                .foregroundStyle(.indigo)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.name).font(.callout)
                                Text("\(t.actionKind.label) · \(t.scheduleKind.label)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .tag(t.id)
                    }
                }
                Divider()
                HStack {
                    Button {
                        let task = ScheduledTask()
                        store.add(task)
                        selection = task.id
                        scheduler.recomputeNextRuns()
                    } label: { Image(systemName: "plus") }
                    Button {
                        if let id = selection {
                            store.remove(id: id)
                            selection = nil
                        }
                    } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                    Spacer()
                    if let id = selection {
                        Button {
                            scheduler.runNow(id: id)
                        } label: { Label("Rodar agora", systemImage: "play.fill") }
                    }
                }
                .padding(8)
            }
            .frame(minWidth: 260)

            // Editor
            ScrollView {
                if let id = selection, let idx = store.config.tasks.firstIndex(where: { $0.id == id }) {
                    editor(taskIndex: idx)
                        .padding(16)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.system(size: 36))
                            .foregroundStyle(.tertiary)
                        Text("Selecione ou crie uma tarefa")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(40)
                }
            }
            .frame(minWidth: 420)
        }
        .frame(minWidth: 760, minHeight: 460)
    }

    private func bindingEnabled(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { store.config.tasks.first(where: { $0.id == id })?.enabled ?? false },
            set: { newVal in
                if let idx = store.config.tasks.firstIndex(where: { $0.id == id }) {
                    store.config.tasks[idx].enabled = newVal
                    store.save()
                    scheduler.recomputeNextRuns()
                }
            }
        )
    }

    @ViewBuilder
    private func editor(taskIndex idx: Int) -> some View {
        let task = $store.config.tasks[idx]
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                TextField("Nome", text: task.name)
                    .font(.title3.bold())
                    .textFieldStyle(.roundedBorder)
                Toggle("Ativa", isOn: task.enabled)
                    .toggleStyle(.switch)
            }

            // Ação
            GroupBox("Ação") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Tipo", selection: task.actionKind) {
                        ForEach(TaskActionKind.allCases) { k in
                            Label(k.label, systemImage: k.systemImage).tag(k)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch store.config.tasks[idx].actionKind {
                    case .script:
                        Text("Comando shell (executado via /bin/bash -lc):")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: task.action.command)
                            .font(.body.monospaced())
                            .frame(minHeight: 80)
                            .padding(4)
                            .background(Color.primary.opacity(0.04))
                    case .reminder:
                        TextField("Título do lembrete", text: task.action.title)
                        TextField("Mensagem", text: task.action.body)
                    case .email:
                        TextField("Destinatário (email)", text: task.action.to)
                        TextField("Assunto", text: task.action.title)
                        TextField("Corpo", text: task.action.body, axis: .vertical)
                            .lineLimit(3...8)
                        Text("Usa o utilitário `mailme`. Precisa estar no PATH (~/.local/bin/mailme).")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    case .mouseClick:
                        mouseClickEditor(task: task)
                    }
                }
                .padding(.vertical, 4)
            }

            // Schedule
            GroupBox("Agendamento") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Tipo", selection: task.scheduleKind) {
                        ForEach(TaskScheduleKind.allCases) { k in Text(k.label).tag(k) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: store.config.tasks[idx].scheduleKind) { _ in
                        scheduler.recomputeNextRuns()
                    }

                    switch store.config.tasks[idx].scheduleKind {
                    case .oneShot:
                        DatePicker("Data/hora", selection: task.schedule.oneShotAt)
                    case .everyMinutes:
                        HStack {
                            Text("A cada")
                            Stepper("", value: task.schedule.intervalMinutes, in: 1...10080)
                                .labelsHidden()
                            Text("\(store.config.tasks[idx].schedule.intervalMinutes) min")
                                .monospacedDigit()
                        }
                    case .daily:
                        HStack {
                            Text("Hora")
                            Stepper("", value: task.schedule.hour, in: 0...23).labelsHidden()
                            Text(String(format: "%02d", store.config.tasks[idx].schedule.hour))
                                .monospacedDigit()
                            Text(":")
                            Stepper("", value: task.schedule.minute, in: 0...59).labelsHidden()
                            Text(String(format: "%02d", store.config.tasks[idx].schedule.minute))
                                .monospacedDigit()
                        }
                    case .weekly:
                        HStack {
                            Picker("Dia", selection: task.schedule.weekday) {
                                Text("Dom").tag(1)
                                Text("Seg").tag(2)
                                Text("Ter").tag(3)
                                Text("Qua").tag(4)
                                Text("Qui").tag(5)
                                Text("Sex").tag(6)
                                Text("Sáb").tag(7)
                            }
                            .pickerStyle(.menu)
                            Stepper("", value: task.schedule.hour, in: 0...23).labelsHidden()
                            Text(String(format: "%02d", store.config.tasks[idx].schedule.hour))
                                .monospacedDigit()
                            Text(":")
                            Stepper("", value: task.schedule.minute, in: 0...59).labelsHidden()
                            Text(String(format: "%02d", store.config.tasks[idx].schedule.minute))
                                .monospacedDigit()
                        }
                    }

                    if let next = store.config.tasks[idx].nextRun {
                        Text("Próxima execução: \(next.formatted(date: .abbreviated, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            // Histórico
            if !store.config.tasks[idx].history.isEmpty {
                GroupBox("Histórico (últimas \(store.config.tasks[idx].history.count))") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(store.config.tasks[idx].history.prefix(10)) { h in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: h.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                    .foregroundStyle(h.ok ? .green : .red)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(h.when.formatted(date: .abbreviated, time: .standard))
                                        .font(.caption.monospaced())
                                    Text(h.detail.isEmpty ? "—" : h.detail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                }
                                Spacer()
                                Text("\(h.durationMs)ms").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Spacer(minLength: 0)
        }
        .onChange(of: store.config.tasks[idx]) { _ in
            store.save()
            scheduler.recomputeNextRuns()
        }
    }

    @ViewBuilder
    private func mouseClickEditor(task: Binding<ScheduledTask>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("X")
                TextField("", value: task.action.pointX, format: .number)
                    .frame(width: 80)
                Text("Y")
                TextField("", value: task.action.pointY, format: .number)
                    .frame(width: 80)
                Picker("Botão", selection: task.action.mouseButton) {
                    Text("Esquerdo").tag(TaskMouseButton.left)
                    Text("Direito").tag(TaskMouseButton.right)
                }
                .pickerStyle(.menu)
                .frame(width: 130)
                Toggle("Duplo", isOn: task.action.doubleClick)
            }
            HStack {
                Button {
                    captureMousePosition(bind: task)
                } label: {
                    if capturing {
                        Label("Capturando em \(captureCountdown)s…", systemImage: "scope")
                    } else {
                        Label("Capturar posição (3s)", systemImage: "scope")
                    }
                }
                .disabled(capturing)
                Spacer()
                if !MouseAutomation.isAccessibilityTrusted() {
                    Text("⚠︎ Sem permissão de Accessibility")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Button("Abrir System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .font(.caption2)
                }
            }
            Text("Coordenadas em pixels da tela principal, origem no canto superior-esquerdo.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func captureMousePosition(bind: Binding<ScheduledTask>) {
        capturing = true
        captureCountdown = 3
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { t in
            captureCountdown -= 1
            if captureCountdown <= 0 {
                t.invalidate()
                let p = MouseAutomation.currentMousePosition()
                bind.wrappedValue.action.pointX = Double(Int(p.x))
                bind.wrappedValue.action.pointY = Double(Int(p.y))
                capturing = false
                store.save()
            }
        }
    }
}
