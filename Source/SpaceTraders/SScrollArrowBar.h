// SScrollArrowBar.h
#pragma once

#include "CoreMinimal.h"
#include "Styling/SlateTypes.h"
#include "Types/SlateEnums.h"
#include "Widgets/DeclarativeSyntaxSupport.h"
#include "Widgets/SCompoundWidget.h"
#include "Widgets/SLeafWidget.h"
#include "ScrollArrowButtonStyle.h"
#include "Styling/SlateWidgetStyleAsset.h"
#include "Styling/SlateStyle.h"

class SBox;
class SButton;
class SScrollBar;

enum class EScrollArrowDirection : uint8
{
	Up,
	Down,
	Left,
	Right
};

/** Plain-C++ mirror of everything the designer can configure; pushed into the Slate widget. */
struct FScrollArrowBarSettings
{
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

	FScrollArrowButtonStyle StartButtonStyle;
	FScrollArrowButtonStyle EndButtonStyle;
};

/** Asks the list to scroll by a (signed) number of items. */
DECLARE_DELEGATE_OneParam(FOnScrollArrowScroll, float /*DeltaInItems*/);

/**
 * Small leaf widget that paints the arrow glyph. Tint comes from the parent button's
 * foreground colour, so it follows the hover / pressed / disabled state automatically.
 */
class SScrollArrowGlyph : public SLeafWidget
{
public:
	SLATE_BEGIN_ARGS(SScrollArrowGlyph)
		: _Direction(EScrollArrowDirection::Up)
	{}
		SLATE_ARGUMENT(EScrollArrowDirection, Direction)
	SLATE_END_ARGS()

	void Construct(const FArguments& InArgs);
	void SetStyle(const FScrollArrowButtonStyle& InStyle);

	virtual int32 OnPaint(const FPaintArgs& Args, const FGeometry& AllottedGeometry, const FSlateRect& MyCullingRect,
		FSlateWindowElementList& OutDrawElements, int32 LayerId, const FWidgetStyle& InWidgetStyle, bool bParentEnabled) const override;
	virtual FVector2D ComputeDesiredSize(float LayoutScaleMultiplier) const override;

private:
	bool HasImage() const;

	EScrollArrowDirection Direction = EScrollArrowDirection::Up;
	FSlateBrush ArrowImage;
	FVector2D GlyphSize = FVector2D(8.0, 8.0);
	float LineThickness = 2.0f;
};

/**
 * [Start arrow] [ SScrollBar ] [End arrow]  (stacked vertically, or side by side when horizontal).
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
	bool CanScrollInDirection(bool bTowardsEnd) const;
	bool IsArrowEnabled(bool bIsEnd) const;
	FSlateColor GetArrowForeground(bool bIsEnd) const;

	bool IsStartEnabled() const { return IsArrowEnabled(false); }
	bool IsEndEnabled() const { return IsArrowEnabled(true); }
	FSlateColor GetStartForeground() const { return GetArrowForeground(false); }
	FSlateColor GetEndForeground() const { return GetArrowForeground(true); }

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
	TSharedRef<SWidget> MakeArrowButton(bool bIsEnd);
	void ApplyStyles();
	void ConfigureButton(const TSharedPtr<SButton>& Button, const TSharedPtr<SBox>& SizeBox,
		const TSharedPtr<SScrollArrowGlyph>& Glyph, FButtonStyle& SlateStyle, const FScrollArrowButtonStyle& Style) const;

private:
	EOrientation Orientation = Orient_Vertical;
	FOnScrollArrowScroll OnScroll;
	TAttribute<EVisibility> UserScrollbarVisibility;
	FScrollArrowBarSettings Settings;

	TSharedPtr<SScrollBar> ScrollBar;

	TSharedPtr<SButton> StartButton;
	TSharedPtr<SButton> EndButton;
	TSharedPtr<SBox> StartSizeBox;
	TSharedPtr<SBox> EndSizeBox;
	TSharedPtr<SScrollArrowGlyph> StartGlyph;
	TSharedPtr<SScrollArrowGlyph> EndGlyph;

	// Owned here so the buttons can keep a stable pointer to their style.
	FButtonStyle StartSlateStyle;
	FButtonStyle EndSlateStyle;

	// Hold-to-repeat state
	int32 HeldDirection = 0; // -1 = towards start, +1 = towards end, 0 = idle
	float HeldTime = 0.0f;
	TWeakPtr<FActiveTimerHandle> HoldTimerHandle;
};
