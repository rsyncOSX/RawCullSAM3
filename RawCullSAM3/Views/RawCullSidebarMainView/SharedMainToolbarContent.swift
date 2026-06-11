//
//  SharedMainToolbarContent.swift
//  RawCullSAM3
//

import SwiftUI

struct SharedMainToolbarContent: ToolbarContent {
    @Bindable var viewModel: RawCullViewModel
    let toggleInspector: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .status) {
            Button(action: toggleInspector) {
                Label("Inspector", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .help("Show inspector")
        }

        ToolbarItem(placement: .status) {
            RatingFilterButtons(
                activeRating: activeRatingInt,
                onSelect: applyRatingFilter,
                onClear: {
                    viewModel.ratingFilter = .all
                    Task(priority: .background) { await viewModel.handleSortOrderChange() }
                },
            )
            .padding(.trailing, 8)
            .disabled(viewModel.selectedSource == nil)
        }
    }

    private var activeRatingInt: Int? {
        switch viewModel.ratingFilter {
        case .all: nil
        case .rejected: -1
        case .keepers: 0
        case let .stars(n): n
        }
    }

    private func applyRatingFilter(_ rating: Int) {
        let newFilter: RatingFilter = switch rating {
        case -1: .rejected
        case 0: .keepers
        default: .stars(rating)
        }
        viewModel.ratingFilter = viewModel.ratingFilter == newFilter ? .all : newFilter
        Task(priority: .background) { await viewModel.handleSortOrderChange() }
    }
}
