// SScrollArrowBar.h
#pragma once

#include "CoreMinimal.h"
#include "Styling/ISlateStyle.h"
#include "Styling/SlateTypes.h"
#include "Styling/SlateWidgetStyleAsset.h" // SLATE_STYLE_ARGUMENT needs USlateWidgetStyleAsset to be complete
#include "Types/SlateEnums.h"
#include "Widgets/DeclarativeSyntaxSupport.h"
#include "Widgets/SCompoundWidget.h"
#include "ScrollArrowButtonStyle.h"
#include "ScrollArrowDefaultTextures.h" // EScrollArrowDirection

class SBorder;
class SBox;
class SButton;
class SScrollBar;

/** Plain-C++ mirror of everything the designer can configure; pushed into the Slate widget. */
struct FScrollArrowBarSettings
{
	FScrollArrowBarSettings()
	{
		SideBarBackground.DrawAs = ESlateBrushDrawType::NoDrawType; // invisible unless the user opts in
	}

	/** Keep the arrow bar on screen (buttons greyed out, track hidden) when nothing can scroll. */
	bool bAlwaysShowScrollBar = false;

	/** Grey out an arrow once its end of the list has been reached. */
	bool bDisableArrowsAtLimits = true;

	/** Items scrolled by a single click. */
	float ClickScrollAmount = 1.0f;

	/** Seconds the button must be held before it starts repeating (Windows-style repeat delay). */
	float HoldRepeatDelay = 0.5f;

	/** Items per second scrolled while the button is held past the repeat delay. */
	float HoldScrollSpeed = 12.0f;

	/** Drawn behind the whole bar (arrows + track) whenever the bar is visible. */
	FSlateBrush SideBarBackground;

	FScrollArrowButtonStyle StartButtonStyle;
	FScrollArrowButtonStyle EndButtonStyle;
};

/** Asks the list to scroll by a (signed) number of items. */
DECLARE_DELEGATE_OneParam(FOnScrollArrowScroll, float /*DeltaInItems*/);

/**
 * [Start arrow] [ SScrollBar ] [End arrow]  (stacked vertically, or side by side when horizontal),
 * on top of an optional background brush.
 *
 * The bar is exactly "Scroll Bar Style -> Thickness" wide (tall when horizontal): the arrows, the
 * track and the background all share that size, so nothing shifts when the thumb appears.
 *
 * The inner SScrollBar is handed to the list view as its ExternalScrollbar, so the list drives the
 * thumb and handles dragging exactly like the stock scroll bar does.
 */
class SScrollArrowBar : public SCompoundWidget
{
public:
	SLATE_BEGIN_ARGS(SScrollArrowBar)
		: _Orientation(Orient_Vertical)
		, _ScrollBarStyle(nullptr)
		, _ScrollbarVisibility(EVisibility::Visible)
	{}
		SLATE_ARGUMENT(EOrientation, Orientation)
		SLATE_STYLE_ARGUMENT(FScrollBarStyle, ScrollBarStyle)
		/** The list's own "Scrollbar Visibility" setting (Collapsed / Hidden hides the whole bar). */
		SLATE_ATTRIBUTE(EVisibility, ScrollbarVisibility)
		SLATE_EVENT(FOnScrollArrowScroll, OnScroll)
	SLATE_END_ARGS()

	void Construct(const FArguments& InArgs);

	/** The scroll bar to give to the list view (SListView::FArguments::ExternalScrollbar). */
	TSharedRef<SScrollBar> GetScrollBar() const { return ScrollBar.ToSharedRef(); }

	void SetSettings(const FScrollArrowBarSettings& InSettings);

private:
	// Visibility / state bindings
	EVisibility GetBarVisibility() const;
	EVisibility GetTrackVisibility() const;
	FOptionalSize GetBarThickness() const;
	bool CanScrollInDirection(bool bTowardsEnd) const;
	bool IsArrowEnabled(bool bIsEnd) const;

	bool IsStartEnabled() const { return IsArrowEnabled(false); }
	bool IsEndEnabled() const { return IsArrowEnabled(true); }

	// Press / hold handling
	void HandleStartPressed() { BeginHold(false); }
	void HandleEndPressed() { BeginHold(true); }
	void HandleStartReleased() { EndHold(); }
	void HandleEndReleased() { EndHold(); }

	void BeginHold(bool bTowardsEnd);
	void EndHold();
	void StopHoldTimer();
	EActiveTimerReturnType HandleHoldTimer(double InCurrentTime, float InDeltaTime);

	// Construction helpers
	EScrollArrowDirection GetDirection(bool bIsEnd) const;
	TSharedRef<SWidget> MakeArrowButton(bool bIsEnd);
	void ApplyStyles();
	void ConfigureButton(const TSharedPtr<SButton>& Button, FButtonStyle& SlateStyle,
		const FScrollArrowButtonStyle& Style, EScrollArrowDirection Direction) const;

private:
	EOrientation Orientation = Orient_Vertical;
	FOnScrollArrowScroll OnScroll;
	TAttribute<EVisibility> UserScrollbarVisibility;
	const FScrollBarStyle* BarStyle = nullptr;
	FScrollArrowBarSettings Settings;

	TSharedPtr<SBorder> BackgroundBorder;
	TSharedPtr<SScrollBar> ScrollBar;

	TSharedPtr<SButton> StartButton;
	TSharedPtr<SButton> EndButton;

	// Owned here so the buttons can keep a stable pointer to their style.
	FButtonStyle StartSlateStyle;
	FButtonStyle EndSlateStyle;

	// Hold-to-repeat state
	int32 HeldDirection = 0; // -1 = towards start, +1 = towards end, 0 = idle
	float HeldTime = 0.0f;
	TWeakPtr<FActiveTimerHandle> HoldTimerHandle;
};
