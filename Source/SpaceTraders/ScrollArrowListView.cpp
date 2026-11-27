// ScrollArrowListView.cpp
#include "ScrollArrowListView.h"

UScrollArrowListView::UScrollArrowListView(const FObjectInitializer& ObjectInitializer)
	: Super(ObjectInitializer)
{
	// Invisible by default; the user opts in by picking a brush.
	SideBarBackground.DrawAs = ESlateBrushDrawType::NoDrawType;
}

TSharedRef<STableViewBase> UScrollArrowListView::RebuildListWidget()
{
	// ConstructListView<> is UListView's hook for custom SListView subclasses; it wires up all the
	// usual UMG list behaviour (entry generation, selection, drag & drop, ...) onto our widget.
	TSharedRef<SScrollArrowListView<UObject*>> NewListView = ConstructListView<SScrollArrowListView>();
	MyArrowListView = NewListView;

	ApplyArrowSettings();
	return NewListView;
}

void UScrollArrowListView::SynchronizeProperties()
{
	Super::SynchronizeProperties();
	ApplyArrowSettings();
}

void UScrollArrowListView::ReleaseSlateResources(bool bReleaseChildren)
{
	Super::ReleaseSlateResources(bReleaseChildren);
	MyArrowListView.Reset();
}

FScrollArrowBarSettings UScrollArrowListView::MakeSlateSettings() const
{
	FScrollArrowBarSettings Settings;
	Settings.bAlwaysShowScrollBar = bAlwaysShowScrollBar;
	Settings.bDisableArrowsAtLimits = bDisableArrowsAtScrollLimits;
	Settings.ClickScrollAmount = ClickScrollAmount;
	Settings.HoldRepeatDelay = HoldRepeatDelay;
	Settings.HoldScrollSpeed = HoldScrollSpeed;
	Settings.SideBarBackground = SideBarBackground;
	Settings.SideBarPadding = SideBarPadding;
	Settings.StartButtonStyle = StartButtonStyle;
	Settings.EndButtonStyle = bUseSameStyleForBothButtons ? StartButtonStyle : EndButtonStyle;
	return Settings;
}

void UScrollArrowListView::ApplyArrowSettings()
{
	if (const TSharedPtr<SScrollArrowListView<UObject*>> ArrowList = MyArrowListView.Pin())
	{
		ArrowList->SetArrowSettings(MakeSlateSettings());
	}
}

void UScrollArrowListView::SetAlwaysShowScrollBar(bool bInAlwaysShowScrollBar)
{
	bAlwaysShowScrollBar = bInAlwaysShowScrollBar;
	ApplyArrowSettings();
}

void UScrollArrowListView::SetSideBarBackground(const FSlateBrush& InBrush)
{
	SideBarBackground = InBrush;
	ApplyArrowSettings();
}

void UScrollArrowListView::SetSideBarPadding(const FMargin& InPadding)
{
	SideBarPadding = InPadding;
	ApplyArrowSettings();
}

void UScrollArrowListView::SetStartButtonStyle(const FScrollArrowButtonStyle& InStyle)
{
	StartButtonStyle = InStyle;
	ApplyArrowSettings();
}

void UScrollArrowListView::SetEndButtonStyle(const FScrollArrowButtonStyle& InStyle)
{
	EndButtonStyle = InStyle;
	ApplyArrowSettings();
}
