// SScrollArrowBar.cpp
#include "SScrollArrowBar.h"

#include "Styling/CoreStyle.h"
#include "Widgets/Input/SButton.h"
#include "Widgets/Layout/SBorder.h"
#include "Widgets/Layout/SBox.h"
#include "Widgets/Layout/SScrollBar.h"
#include "Widgets/SBoxPanel.h"

namespace
{
	// Fractions of the scroll track; tight enough to be exact for lists with 100k+ items.
	constexpr float LimitTolerance = 1.e-5f;

	// Per-state tint multipliers used when a state has no image of its own.
	const FLinearColor NormalStateTint(1.0f, 1.0f, 1.0f, 1.0f);
	const FLinearColor HoveredStateTint(1.4f, 1.4f, 1.4f, 1.0f);
	const FLinearColor PressedStateTint(0.7f, 0.7f, 0.7f, 1.0f);
	const FLinearColor DisabledStateTint(0.45f, 0.45f, 0.45f, 0.5f);

	// The built-in arrow texture is pure white; this makes its idle colour a soft grey.
	const FLinearColor BuiltInArrowBaseTint(0.7f, 0.7f, 0.7f, 1.0f);

	/** A brush the user has not touched: "Draw As = Image" with no texture. */
	bool IsUnsetBrush(const FSlateBrush& Brush)
	{
		return Brush.DrawAs == ESlateBrushDrawType::Image
			&& Brush.GetResourceObject() == nullptr
			&& Brush.GetResourceName().IsNone();
	}

	/**
	 * Picks what a state really draws:
	 *   - the user's brush if they set one,
	 *   - else the Normal brush if it has a texture (tinted for this state),
	 *   - else the built-in arrow for this button's direction.
	 */
	FSlateBrush ResolveBrush(const FSlateBrush& StateBrush, const FSlateBrush& NormalBrush,
		EScrollArrowDirection Direction, const FLinearColor& StateTint)
	{
		if (!IsUnsetBrush(StateBrush))
		{
			return StateBrush;
		}

		FSlateBrush Result;
		FLinearColor BaseTint;

		if (!IsUnsetBrush(NormalBrush))
		{
			Result = NormalBrush;
			BaseTint = NormalBrush.TintColor.GetSpecifiedColor();
		}
		else
		{
			Result.DrawAs = ESlateBrushDrawType::Image;
			Result.SetResourceObject(FScrollArrowDefaultTextures::Get().GetTexture(Direction));
			BaseTint = StateBrush.TintColor.GetSpecifiedColor() * BuiltInArrowBaseTint;
		}

		Result.TintColor = FSlateColor(BaseTint * StateTint);
		return Result;
	}
}

void SScrollArrowBar::Construct(const FArguments& InArgs)
{
	Orientation = InArgs._Orientation;
	OnScroll = InArgs._OnScroll;
	UserScrollbarVisibility = InArgs._ScrollbarVisibility;

	BarStyle = InArgs._ScrollBarStyle
		? InArgs._ScrollBarStyle
		: &FCoreStyle::Get().GetWidgetStyle<FScrollBarStyle>("Scrollbar");

	SAssignNew(ScrollBar, SScrollBar)
		.Style(BarStyle)
		.Orientation(Orientation);

	const TSharedRef<SWidget> StartWidget = MakeArrowButton(/*bIsEnd*/ false);
	const TSharedRef<SWidget> EndWidget = MakeArrowButton(/*bIsEnd*/ true);

	// The track slot is pinned to exactly the style thickness. Hidden (not Collapsed) keeps the slot,
	// so the arrows stay at the ends and the bar never changes width when the thumb appears.
	const TSharedRef<SBox> TrackBox =
		SNew(SBox)
		.Visibility(this, &SScrollArrowBar::GetTrackVisibility)
		[
			ScrollBar.ToSharedRef()
		];

	TSharedPtr<SWidget> Layout;
	if (Orientation == Orient_Vertical)
	{
		TrackBox->SetWidthOverride(MakeAttributeSP(this, &SScrollArrowBar::GetBarThickness));
		Layout =
			SNew(SVerticalBox)
			+ SVerticalBox::Slot().AutoHeight()[ StartWidget ]
			+ SVerticalBox::Slot().FillHeight(1.0f)[ TrackBox ]
			+ SVerticalBox::Slot().AutoHeight()[ EndWidget ];
	}
	else
	{
		TrackBox->SetHeightOverride(MakeAttributeSP(this, &SScrollArrowBar::GetBarThickness));
		Layout =
			SNew(SHorizontalBox)
			+ SHorizontalBox::Slot().AutoWidth()[ StartWidget ]
			+ SHorizontalBox::Slot().FillWidth(1.0f)[ TrackBox ]
			+ SHorizontalBox::Slot().AutoWidth()[ EndWidget ];
	}

	// Background for the whole bar (only drawn if the user picked a brush).
	ChildSlot
	[
		SAssignNew(BackgroundBorder, SBorder)
		.BorderImage(&Settings.SideBarBackground)
		.Padding(0.0f)
		[
			Layout.ToSharedRef()
		]
	];

	SetVisibility(MakeAttributeSP(this, &SScrollArrowBar::GetBarVisibility));

	ApplyStyles();
}

EScrollArrowDirection SScrollArrowBar::GetDirection(bool bIsEnd) const
{
	const bool bVertical = (Orientation == Orient_Vertical);
	if (bIsEnd)
	{
		return bVertical ? EScrollArrowDirection::Down : EScrollArrowDirection::Right;
	}
	return bVertical ? EScrollArrowDirection::Up : EScrollArrowDirection::Left;
}

TSharedRef<SWidget> SScrollArrowBar::MakeArrowButton(bool bIsEnd)
{
	TSharedPtr<SButton>& Button = bIsEnd ? EndButton : StartButton;
	FButtonStyle& SlateStyle = bIsEnd ? EndSlateStyle : StartSlateStyle;

	if (bIsEnd)
	{
		SAssignNew(Button, SButton)
			.ButtonStyle(&SlateStyle)
			.ContentPadding(FMargin(0.0f))
			.IsFocusable(false) // never steal keyboard / gamepad focus from the list
			.IsEnabled(this, &SScrollArrowBar::IsEndEnabled)
			.OnPressed(this, &SScrollArrowBar::HandleEndPressed)
			.OnReleased(this, &SScrollArrowBar::HandleEndReleased);
	}
	else
	{
		SAssignNew(Button, SButton)
			.ButtonStyle(&SlateStyle)
			.ContentPadding(FMargin(0.0f))
			.IsFocusable(false)
			.IsEnabled(this, &SScrollArrowBar::IsStartEnabled)
			.OnPressed(this, &SScrollArrowBar::HandleStartPressed)
			.OnReleased(this, &SScrollArrowBar::HandleStartReleased);
	}

	// Square button, sized by the scroll bar style thickness.
	const TSharedRef<SBox> SizeBox =
		SNew(SBox)
		[
			Button.ToSharedRef()
		];
	SizeBox->SetWidthOverride(MakeAttributeSP(this, &SScrollArrowBar::GetBarThickness));
	SizeBox->SetHeightOverride(MakeAttributeSP(this, &SScrollArrowBar::GetBarThickness));
	return SizeBox;
}

void SScrollArrowBar::SetSettings(const FScrollArrowBarSettings& InSettings)
{
	Settings = InSettings; // keeps the address the background border points at
	ApplyStyles();
	ScrollBar->InvalidateStyle();
	Invalidate(EInvalidateWidgetReason::Layout);
}

void SScrollArrowBar::ApplyStyles()
{
	ConfigureButton(StartButton, StartSlateStyle, Settings.StartButtonStyle, GetDirection(false));
	ConfigureButton(EndButton, EndSlateStyle, Settings.EndButtonStyle, GetDirection(true));
}

void SScrollArrowBar::ConfigureButton(const TSharedPtr<SButton>& Button, FButtonStyle& SlateStyle,
	const FScrollArrowButtonStyle& Style, EScrollArrowDirection Direction) const
{
	const FSlateBrush& Normal = Style.NormalImage;

	SlateStyle
		.SetNormal(ResolveBrush(Style.NormalImage, Normal, Direction, NormalStateTint))
		.SetHovered(ResolveBrush(Style.HoveredImage, Normal, Direction, HoveredStateTint))
		.SetPressed(ResolveBrush(Style.PressedImage, Normal, Direction, PressedStateTint))
		.SetDisabled(ResolveBrush(Style.DisabledImage, Normal, Direction, DisabledStateTint))
		.SetNormalPadding(FMargin(0.0f))
		.SetPressedPadding(FMargin(0.0f));

	Button->SetButtonStyle(&SlateStyle);
}

// ---------------------------------------------------------------------------------------------
// Visibility / enabled state
// ---------------------------------------------------------------------------------------------

FOptionalSize SScrollArrowBar::GetBarThickness() const
{
	return FOptionalSize(BarStyle ? BarStyle->Thickness : 16.0f);
}

EVisibility SScrollArrowBar::GetBarVisibility() const
{
	// The list's own "Scrollbar Visibility" (Collapsed / Hidden) always wins.
	const EVisibility UserVisibility = UserScrollbarVisibility.Get(EVisibility::Visible);
	if (!UserVisibility.IsVisible())
	{
		return UserVisibility;
	}

	if (ScrollBar->IsNeeded())
	{
		// Content overflows: behave like the stock scroll bar (also honours SetScrollbarVisibility at runtime).
		return ScrollBar->ShouldBeVisible();
	}

	// Nothing to scroll: either keep the (greyed out) arrows around, or vanish like a normal scroll bar.
	return Settings.bAlwaysShowScrollBar ? EVisibility::Visible : EVisibility::Collapsed;
}

EVisibility SScrollArrowBar::GetTrackVisibility() const
{
	return ScrollBar->IsNeeded() ? EVisibility::Visible : EVisibility::Hidden;
}

bool SScrollArrowBar::CanScrollInDirection(bool bTowardsEnd) const
{
	if (!ScrollBar->IsNeeded())
	{
		return false;
	}

	const float Remaining = bTowardsEnd ? ScrollBar->DistanceFromBottom() : ScrollBar->DistanceFromTop();
	return Remaining > LimitTolerance;
}

bool SScrollArrowBar::IsArrowEnabled(bool bIsEnd) const
{
	if (!ScrollBar->IsNeeded())
	{
		return false;
	}

	return Settings.bDisableArrowsAtLimits ? CanScrollInDirection(bIsEnd) : true;
}

// ---------------------------------------------------------------------------------------------
// Click + hold-to-repeat
// ---------------------------------------------------------------------------------------------

void SScrollArrowBar::BeginHold(bool bTowardsEnd)
{
	StopHoldTimer();

	if (!CanScrollInDirection(bTowardsEnd))
	{
		HeldDirection = 0;
		return;
	}

	HeldDirection = bTowardsEnd ? 1 : -1;
	HeldTime = 0.0f;

	// The plain "click": one step immediately on press.
	OnScroll.ExecuteIfBound(static_cast<float>(HeldDirection) * Settings.ClickScrollAmount);

	// After the repeat delay the timer takes over and keeps scrolling until release / end of list.
	HoldTimerHandle = RegisterActiveTimer(0.0f, FWidgetActiveTimerDelegate::CreateSP(this, &SScrollArrowBar::HandleHoldTimer));
}

void SScrollArrowBar::EndHold()
{
	HeldDirection = 0;
	StopHoldTimer();
}

void SScrollArrowBar::StopHoldTimer()
{
	if (const TSharedPtr<FActiveTimerHandle> Handle = HoldTimerHandle.Pin())
	{
		UnRegisterActiveTimer(Handle.ToSharedRef());
	}
	HoldTimerHandle.Reset();
}

EActiveTimerReturnType SScrollArrowBar::HandleHoldTimer(double InCurrentTime, float InDeltaTime)
{
	if (HeldDirection == 0)
	{
		return EActiveTimerReturnType::Stop;
	}

	HeldTime += InDeltaTime;
	if (HeldTime < Settings.HoldRepeatDelay)
	{
		return EActiveTimerReturnType::Continue;
	}

	if (!CanScrollInDirection(HeldDirection > 0))
	{
		// Reached the end of the list: nothing left to do until the button is pressed again.
		HeldDirection = 0;
		return EActiveTimerReturnType::Stop;
	}

	OnScroll.ExecuteIfBound(static_cast<float>(HeldDirection) * Settings.HoldScrollSpeed * InDeltaTime);
	return EActiveTimerReturnType::Continue;
}
