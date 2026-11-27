// SScrollArrowBar.cpp
#include "SScrollArrowBar.h"

#include "Styling/CoreStyle.h"
#include "Widgets/Images/SImage.h"
#include "Widgets/Input/SButton.h"
#include "Widgets/Layout/SBorder.h"
#include "Widgets/Layout/SBox.h"
#include "Widgets/Layout/SScrollBar.h"
#include "Widgets/SBoxPanel.h"

namespace
{
	// Fractions of the scroll track; tight enough to be exact for lists with 100k+ items.
	constexpr float LimitTolerance = 1.e-5f;

	// --- Default look (used while the user has not assigned a Normal texture) --------------------
	// Solid square behind the arrow; this is what highlights as a whole on hover.
	const FLinearColor DefaultNormalSquare(0.10f, 0.10f, 0.10f, 1.0f);
	const FLinearColor DefaultHoveredSquare(0.22f, 0.22f, 0.22f, 1.0f);
	const FLinearColor DefaultPressedSquare(0.36f, 0.36f, 0.36f, 1.0f);
	const FLinearColor DefaultDisabledSquare(0.06f, 0.06f, 0.06f, 0.6f);

	// Tint of the built-in arrow on top of the square.
	const FLinearColor DefaultNormalArrow(0.75f, 0.75f, 0.75f, 1.0f);
	const FLinearColor DefaultHoveredArrow(1.0f, 1.0f, 1.0f, 1.0f);
	const FLinearColor DefaultPressedArrow(0.55f, 0.55f, 0.55f, 1.0f);
	const FLinearColor DefaultDisabledArrow(0.30f, 0.30f, 0.30f, 0.6f);

	// --- Per-state multipliers when inheriting a user-supplied Normal texture ---------------------
	const FLinearColor InheritNormalTint(1.0f, 1.0f, 1.0f, 1.0f);
	const FLinearColor InheritHoveredTint(1.4f, 1.4f, 1.4f, 1.0f);
	const FLinearColor InheritPressedTint(0.7f, 0.7f, 0.7f, 1.0f);
	const FLinearColor InheritDisabledTint(0.45f, 0.45f, 0.45f, 0.5f);

	/** A brush the user has not touched: "Draw As = Image" with no texture. */
	bool IsUnsetBrush(const FSlateBrush& Brush)
	{
		return Brush.DrawAs == ESlateBrushDrawType::Image
			&& Brush.GetResourceObject() == nullptr
			&& Brush.GetResourceName().IsNone();
	}

	/**
	 * What a state draws as the button background:
	 *   - the user's brush if they set one,
	 *   - else the user's Normal brush (tinted for this state) if that has a texture,
	 *   - else a solid default square.
	 */
	FSlateBrush ResolveBackground(const FSlateBrush& StateBrush, const FSlateBrush& NormalBrush,
		const FLinearColor& DefaultSquareColor, const FLinearColor& InheritTint)
	{
		if (!IsUnsetBrush(StateBrush))
		{
			return StateBrush;
		}

		FSlateBrush Result;
		if (!IsUnsetBrush(NormalBrush))
		{
			Result = NormalBrush;
			Result.TintColor = FSlateColor(NormalBrush.TintColor.GetSpecifiedColor() * InheritTint);
		}
		else
		{
			// Unset brush = plain solid fill of the whole button.
			Result.DrawAs = ESlateBrushDrawType::Image;
			Result.TintColor = FSlateColor(StateBrush.TintColor.GetSpecifiedColor() * DefaultSquareColor);
		}
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
		.Orientation(Orientation)
		.Padding(InArgs._ScrollBarPadding);

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

	// ChildSlot padding = sidebar padding (outside); the border inside it draws the sidebar background.
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
	TSharedPtr<SImage>& Glyph = bIsEnd ? EndGlyph : StartGlyph;
	FButtonStyle& SlateStyle = bIsEnd ? EndSlateStyle : StartSlateStyle;
	FSlateBrush& ArrowBrush = bIsEnd ? EndArrowBrush : StartArrowBrush;

	// Built-in arrow, drawn on top of the button square. Hidden (NoDrawType) when custom textures are used.
	if (bIsEnd)
	{
		SAssignNew(Glyph, SImage)
			.Image(&ArrowBrush)
			.ColorAndOpacity(this, &SScrollArrowBar::GetEndArrowTint)
			.Visibility(EVisibility::HitTestInvisible);
	}
	else
	{
		SAssignNew(Glyph, SImage)
			.Image(&ArrowBrush)
			.ColorAndOpacity(this, &SScrollArrowBar::GetStartArrowTint)
			.Visibility(EVisibility::HitTestInvisible);
	}

	if (bIsEnd)
	{
		SAssignNew(Button, SButton)
			.ButtonStyle(&SlateStyle)
			.ContentPadding(FMargin(0.0f))
			.IsFocusable(false) // never steal keyboard / gamepad focus from the list
			.IsEnabled(this, &SScrollArrowBar::IsEndEnabled)
			.OnPressed(this, &SScrollArrowBar::HandleEndPressed)
			.OnReleased(this, &SScrollArrowBar::HandleEndReleased)
			[
				Glyph.ToSharedRef()
			];
	}
	else
	{
		SAssignNew(Button, SButton)
			.ButtonStyle(&SlateStyle)
			.ContentPadding(FMargin(0.0f))
			.IsFocusable(false)
			.IsEnabled(this, &SScrollArrowBar::IsStartEnabled)
			.OnPressed(this, &SScrollArrowBar::HandleStartPressed)
			.OnReleased(this, &SScrollArrowBar::HandleStartReleased)
			[
				Glyph.ToSharedRef()
			];
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
	ChildSlot.SetPadding(Settings.SideBarPadding);

	ConfigureButton(StartButton, StartGlyph, StartSlateStyle, StartArrowBrush, Settings.StartButtonStyle, GetDirection(false));
	ConfigureButton(EndButton, EndGlyph, EndSlateStyle, EndArrowBrush, Settings.EndButtonStyle, GetDirection(true));

	if (BackgroundBorder.IsValid())
	{
		BackgroundBorder->Invalidate(EInvalidateWidgetReason::Paint);
	}
}

void SScrollArrowBar::ConfigureButton(const TSharedPtr<SButton>& Button, const TSharedPtr<SImage>& Glyph, FButtonStyle& SlateStyle,
	FSlateBrush& ArrowBrush, const FScrollArrowButtonStyle& Style, EScrollArrowDirection Direction) const
{
	const FSlateBrush& Normal = Style.NormalImage;

	SlateStyle
		.SetNormal(ResolveBackground(Style.NormalImage, Normal, DefaultNormalSquare, InheritNormalTint))
		.SetHovered(ResolveBackground(Style.HoveredImage, Normal, DefaultHoveredSquare, InheritHoveredTint))
		.SetPressed(ResolveBackground(Style.PressedImage, Normal, DefaultPressedSquare, InheritPressedTint))
		.SetDisabled(ResolveBackground(Style.DisabledImage, Normal, DefaultDisabledSquare, InheritDisabledTint))
		.SetNormalPadding(FMargin(0.0f))
		.SetPressedPadding(FMargin(0.0f));

	Button->SetButtonStyle(&SlateStyle);

	// The built-in arrow is only shown when the user supplied no Normal texture (their art has its own arrow).
	ArrowBrush = FSlateBrush();
	if (IsUnsetBrush(Style.NormalImage))
	{
		ArrowBrush.DrawAs = ESlateBrushDrawType::Image;
		ArrowBrush.SetResourceObject(FScrollArrowDefaultTextures::Get().GetTexture(Direction));
	}
	else
	{
		ArrowBrush.DrawAs = ESlateBrushDrawType::NoDrawType;
	}
	Glyph->Invalidate(EInvalidateWidgetReason::Paint);
}

// ---------------------------------------------------------------------------------------------
// Visibility / enabled state
// ---------------------------------------------------------------------------------------------

FOptionalSize SScrollArrowBar::GetBarThickness() const
{
	return FOptionalSize(BarStyle ? BarStyle->Thickness : 16.0f);
}

FSlateColor SScrollArrowBar::GetArrowTint(bool bIsEnd) const
{
	const TSharedPtr<SButton>& Button = bIsEnd ? EndButton : StartButton;

	if (!Button.IsValid() || !Button->IsEnabled())
	{
		return FSlateColor(DefaultDisabledArrow);
	}
	if (Button->IsPressed())
	{
		return FSlateColor(DefaultPressedArrow);
	}
	if (Button->IsHovered())
	{
		return FSlateColor(DefaultHoveredArrow);
	}
	return FSlateColor(DefaultNormalArrow);
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
