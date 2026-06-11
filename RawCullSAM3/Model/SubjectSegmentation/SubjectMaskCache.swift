import Foundation

actor SubjectMaskCache {
    private var entries: [SubjectMaskCacheKey: SubjectMaskCacheEntry] = [:]

    func result(for key: SubjectMaskCacheKey) -> SubjectSegmentationResult? {
        entries[key]?.result
    }

    func store(_ result: SubjectSegmentationResult, for key: SubjectMaskCacheKey) {
        entries[key] = SubjectMaskCacheEntry(result: result)
    }

    func removeAll() {
        entries.removeAll()
    }
}
