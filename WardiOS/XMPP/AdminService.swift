import Foundation

// MARK: - Service discovery

extension XMPPSession {
    func discoInfo(_ jid: String) async -> XMLNode? {
        await iqRequest("<query xmlns='\(NS.discoInfo)'/>", to: jid, timeout: 12)
    }

    func discoItems(_ jid: String, node: String? = nil) async -> XMLNode? {
        let nodeAttribute = node.map { " node='\(XML.escape($0))'" } ?? ""
        return await iqRequest("<query xmlns='\(NS.discoItems)'\(nodeAttribute)/>", to: jid, timeout: 15)
    }

    func discoverCommands() async {
        var found: [String: AdminCommand] = [:]
        var services: Set<String> = [account.domain]
        if let items = await discoItems(account.domain) {
            for item in items.child("query", xmlns: NS.discoItems)?.children("item") ?? [] {
                if let jid = item.attr("jid") { services.insert(jid) }
            }
        }
        for service in services.prefix(20) {
            let info = await discoInfo(service)
            let supports = info?.child("query", xmlns: NS.discoInfo)?.children("feature")
                .contains { $0.attr("var") == NS.commands } ?? false
            if !supports && service != account.domain { continue }
            var items = await discoItems(service, node: NS.commands)
            if items == nil { items = await discoItems(service) }
            for item in items?.child("query", xmlns: NS.discoItems)?.children("item") ?? [] {
                guard let node = item.attr("node"), !node.isEmpty else { continue }
                let name = item.attr("name", node)
                let command = AdminCommand(node: node, name: name, jid: item.attr("jid", service))
                found[command.id] = command
            }
        }
        discoCommands = found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        onCommands?(discoCommands)
    }

    // MARK: - Ad-hoc commands (XEP-0050)

    func executeCommand(_ command: AdminCommand, action: String = "execute") async -> AdminForm? {
        let xml = "<command xmlns='\(NS.commands)' node='\(XML.escape(command.node))' action='\(XML.escape(action))'/>"
        guard let result = await iqRequest(xml, to: command.jid, type: "set", timeout: 45) else { return nil }
        if result.attr("type") == "error" {
            onToast?("The server could not run this command.", true)
            return nil
        }
        var form = parseCommand(result, fallbackTitle: command.name)
        form?.jid = command.jid
        form?.node = command.node
        return form
    }

    func submitForm(_ form: AdminForm, action: String) async -> AdminForm? {
        var values: [String] = []
        var formType = ""
        for field in form.fields {
            if field.varName == "FORM_TYPE" { formType = field.value }
            if field.type == "fixed" { continue }
            if field.type == "hidden" && field.varName == "FORM_TYPE" { continue }
            let rawValues = field.value.components(separatedBy: "\n").filter { !$0.isEmpty }
            if rawValues.isEmpty {
                values.append("<field var='\(XML.escape(field.varName))'><value></value></field>")
            } else {
                for value in rawValues {
                    values.append("<field var='\(XML.escape(field.varName))'><value>\(XML.escape(value))</value></field>")
                }
            }
        }
        if !formType.isEmpty {
            values.insert("<field var='FORM_TYPE' type='hidden'><value>\(XML.escape(formType))</value></field>", at: 0)
        }
        let x = "<x xmlns='\(NS.data)' type='submit'>\(values.joined())</x>"
        let xml = "<command xmlns='\(NS.commands)' node='\(XML.escape(form.node))' sessionid='\(XML.escape(form.sessionId))' action='\(XML.escape(action))'>\(x)</command>"
        guard let result = await iqRequest(xml, to: form.jid, type: "set", timeout: 45) else { return nil }
        var updated = parseCommand(result, fallbackTitle: form.title) ?? form
        updated.jid = form.jid
        updated.node = form.node
        return updated
    }

    func parseCommand(_ result: XMLNode, fallbackTitle: String) -> AdminForm? {
        guard let command = result.child("command", xmlns: NS.commands) else { return nil }
        let sessionID = command.attr("sessionid", "")
        let status = command.attr("status", "completed")
        let notes = command.children("note").map { $0.trimmedText }
        let title = command.child("actions")?.attr("execute", fallbackTitle) ?? fallbackTitle
        let instructions = command.child("instructions")?.trimmedText ?? ""
        var fields: [AdminField] = []
        if let x = command.child("x", xmlns: NS.data) {
            for field in x.children("field") {
                let varName = field.attr("var", "")
                guard !varName.isEmpty else { continue }
                let type = field.attr("type", "text-single")
                let label = field.attr("label", varName)
                let desc = field.child("desc")?.trimmedText ?? ""
                let required = field.child("required") != nil
                let values = field.children("value").map { $0.allText }
                let options = field.children("option").map { option in
                    (option.attr("label", option.child("value")?.allText ?? ""),
                     option.child("value")?.allText ?? "")
                }
                let media = field.child("media", xmlns: "urn:xmpp:media-element")?.child("uri")?.trimmedText
                fields.append(AdminField(varName: varName, type: type, label: label,
                                         value: values.joined(separator: "\n"), options: options,
                                         required: required, desc: desc, media: media))
            }
        }
        var form = AdminForm(sessionId: sessionID, title: title, instructions: instructions,
                             fields: fields, submitLabel: "Submit", actions: ["complete"],
                             notes: notes, status: status)
        form.jid = result.attr("from", "")
        form.node = command.attr("node", "")
        return form
    }
}
