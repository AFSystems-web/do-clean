import Foundation

public extension StructurePreset {
    static let byTypeID = "type", byDateID = "date", creativeID = "creative", minimalID = "minimal"

    /// "По типу", "По дате", "Творческий", "Минимал".
    static func builtIn(language: Language = .ru) -> [StructurePreset] {
        let ru = language == .ru
        func f(_ r: String, _ e: String) -> String { ru ? r : e }

        func rule(_ id: String, _ ruName: String, _ enName: String, _ ext: String, ut: [String] = [], target: String) -> StructureRule {
            StructureRule(id: id, name: f(ruName, enName), extensions: ext.split(separator: " ").map(String.init), utTypes: ut, target: target)
        }
        let video = f("Видео", "Video"), photo = f("Фото", "Photos"), docs = f("Документы", "Documents"), archives = f("Архивы", "Archives")
        let installers = f("Установщики", "Installers"), audio = f("Аудио", "Audio"), design = f("Дизайн", "Design"), code = f("Код", "Code")

        let byType = StructurePreset(
            id: byTypeID, title: L10n(ru: "По типу", en: "By type"),
            subtitle: L10n(ru: "Видео, Фото, Документы, Архивы, Установщики, Аудио, Дизайн, Код", en: "Video, Photos, Documents, Archives, Installers, Audio, Design, Code"),
            rules: [
                rule("v", "Видео", "Video", "mp4 mov m4v avi mkv webm mts m2ts mxf wmv mpg mpeg 3gp", ut: ["public.movie"], target: video),
                rule("d", "Дизайн", "Design", "psd psb ai indd sketch fig xd svg eps afdesign afphoto aep-template fbx obj stl glb gltf", target: design),
                rule("p", "Фото", "Photos", "jpg jpeg png heic heif gif tif tiff webp bmp raw cr2 cr3 nef arw dng orf rw2", ut: ["public.image"], target: photo),
                rule("a", "Аудио", "Audio", "mp3 wav aif aiff flac m4a aac ogg opus wma", ut: ["public.audio"], target: audio),
                rule("i", "Установщики", "Installers", "dmg pkg mpkg iso", target: installers),
                rule("z", "Архивы", "Archives", "zip rar 7z tar gz tgz bz2 xz", ut: ["public.archive"], target: archives),
                rule("c", "Код", "Code", "swift py js ts jsx tsx json html css scss sh c cpp h hpp java kt rs go rb php sql yml yaml toml", target: code),
                rule("t", "Документы", "Documents", "pdf doc docx xls xlsx ppt pptx pages numbers key txt rtf md csv epub odt ods odp", ut: ["public.composite-content", "public.text"], target: docs),
            ], isBuiltIn: true)

        let byDate = StructurePreset(
            id: byDateID, title: L10n(ru: "По дате", en: "By date"),
            subtitle: L10n(ru: "2026/10 Октябрь", en: "2026/10 October"),
            rules: [StructureRule(id: "all", name: f("Все файлы по дате изменения", "All files by modified date"), target: "{year}/{month} {monthName}", matchesAll: true)],
            isBuiltIn: true)

        let creative = StructurePreset(
            id: creativeID, title: L10n(ru: "Творческий", en: "Creative"),
            subtitle: L10n(ru: "Проекты/<проект>/{Исходники, Рендеры, Монтаж, Звук, Экспорт}", en: "Projects/<project>/{Sources, Renders, Edit, Audio, Exports}"),
            strategy: .creative,
            projectLayout: ProjectLayout(root: f("Проекты", "Projects"), sources: f("Исходники", "Sources"), renders: f("Рендеры", "Renders"),
                                         edit: f("Монтаж", "Edit"), audio: f("Звук", "Audio"), exports: f("Экспорт", "Exports")),
            isBuiltIn: true)

        let inbox = f("Входящие", "Inbox"), wip = f("В работе", "In progress"), archive = f("Архив", "Archive")
        let minimal = StructurePreset(
            id: minimalID, title: L10n(ru: "Минимал", en: "Minimal"),
            subtitle: L10n(ru: "Входящие / В работе / Архив", en: "Inbox / In progress / Archive"),
            rules: [
                StructureRule(id: "new", name: f("Свежее (до 14 дней)", "Recent (under 14 days)"), target: inbox, newerThanDays: 14, matchesAll: true),
                StructureRule(id: "old", name: f("Старше 90 дней", "Older than 90 days"), target: archive, olderThanDays: 90, matchesAll: true),
                StructureRule(id: "mid", name: f("Остальное", "Everything else"), target: wip, matchesAll: true),
            ], folders: [inbox, wip, archive], isBuiltIn: true)

        return [byType, byDate, creative, minimal]
    }

    static func builtIn(id: String, language: Language = .ru) -> StructurePreset? { builtIn(language: language).first { $0.id == id } }

    /// Short CLI names: type | date | creative | minimal.
    static func builtIn(cliName: String, language: Language = .ru) -> StructurePreset? {
        builtIn(id: ["type": byTypeID, "date": byDateID, "creative": creativeID, "minimal": minimalID][cliName] ?? cliName, language: language)
    }
}
