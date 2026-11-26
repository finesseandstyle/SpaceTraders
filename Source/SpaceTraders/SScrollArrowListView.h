// SScrollArrowListView.h
#pragma once

#include "CoreMinimal.h"
#include "Widgets/SBoxPanel.h"
#include "Widgets/Views/SListView.h"
#include "SScrollArrowBar.h"

/**
 * SListView that swaps its built-in scroll bar for an SScrollArrowBar (scroll bar + two arrow buttons).
 *
 * Used as the ListViewT template argument of UListView::ConstructListView<>(), which is Epic's
 * supported hook for custom SListView subclasses.
 */
template <typename ItemType>
class SScrollArrowListView : public SListView<ItemType>
{
public:
	void Construct(const typename SListView<ItemType>::FArguments& InArgs)
	{
		const EOrientation ListOrientation = InArgs._Orientation;

		SAssignNew(ArrowBar, SScrollArrowBar)
			.Orientation(ListOrientation)
			.ScrollBarStyle(InArgs._ScrollBarStyle)        // the list's own "Scroll Bar Style"
			.ScrollbarVisibility(InArgs._ScrollbarVisibility)
			.OnScroll(this, &SScrollArrowListView::HandleArrowScroll);

		// Hand our scroll bar to the list; it will drive the thumb and react to dragging.
		typename SListView<ItemType>::FArguments ListArgs(InArgs);
		ListArgs._ExternalScrollbar = ArrowBar->GetScrollBar();
		SListView<ItemType>::Construct(ListArgs);

		// With an external scroll bar the list only contains the item panel. Put the bar next to it.
		const TSharedRef<SWidget> ListContent = this->ChildSlot.GetWidget();

		if (ListOrientation == Orient_Vertical)
		{
			this->ChildSlot
			[
				SNew(SHorizontalBox)
				+ SHorizontalBox::Slot().FillWidth(1.0f)[ ListContent ]
				+ SHorizontalBox::Slot().AutoWidth()[ ArrowBar.ToSharedRef() ]
			];
		}
		else
		{
			this->ChildSlot
			[
				SNew(SVerticalBox)
				+ SVerticalBox::Slot().FillHeight(1.0f)[ ListContent ]
				+ SVerticalBox::Slot().AutoHeight()[ ArrowBar.ToSharedRef() ]
			];
		}
	}

	void SetArrowSettings(const FScrollArrowBarSettings& InSettings)
	{
		if (ArrowBar.IsValid())
		{
			ArrowBar->SetSettings(InSettings);
		}
	}

private:
	/** Offsets are in items, same unit as SetScrollOffset / GetScrollOffset. The list clamps the far end. */
	void HandleArrowScroll(float DeltaInItems)
	{
		const float NewOffset = FMath::Max(0.0f, this->GetScrollOffset() + DeltaInItems);
		this->SetScrollOffset(NewOffset);
	}

	TSharedPtr<SScrollArrowBar> ArrowBar;
};
