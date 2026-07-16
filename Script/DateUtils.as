namespace DateUtils
{
    
    const FText mon1 = NSLOCTEXT("SpaceTradersDate", "Month_Jan", "January");
    const FText mon2 = NSLOCTEXT("SpaceTradersDate", "Month_Feb", "February");
    const FText mon3 = NSLOCTEXT("SpaceTradersDate", "Month_Mar", "March");
    const FText mon4 = NSLOCTEXT("SpaceTradersDate", "Month_Apr", "April");
    const FText mon5 = NSLOCTEXT("SpaceTradersDate", "Month_May", "May");
    const FText mon6 = NSLOCTEXT("SpaceTradersDate", "Month_Jun", "June");
    const FText mon7 = NSLOCTEXT("SpaceTradersDate", "Month_Jul", "July");
    const FText mon8 = NSLOCTEXT("SpaceTradersDate", "Month_Aug", "August");
    const FText mon9 = NSLOCTEXT("SpaceTradersDate", "Month_Sep", "September");
    const FText mon10 = NSLOCTEXT("SpaceTradersDate", "Month_Oct", "October");
    const FText mon11 = NSLOCTEXT("SpaceTradersDate", "Month_Nov", "November");
    const FText mon12 = NSLOCTEXT("SpaceTradersDate", "Month_Dec", "December");

    FText GetMonth(int MonthIndex)
    {
        switch (MonthIndex)
        {
            case 0: return mon1;
            case 1: return mon2;
            case 2: return mon3;
            case 3: return mon4;
            case 4: return mon5;
            case 5: return mon6;
            case 6: return mon7;
            case 7: return mon8;
            case 8: return mon9;
            case 9: return mon10;
            case 10: return mon11;
            case 11: return mon12; 
        }
        return FText::AsDateTime(FDateTime::Now());
    }

    // Format any date to "[Day] [MonthName] [Year]"
    FText FormatTurnDate(FDateTime DateToFormat)
    {
        int MonthIndex = Math::Clamp(DateToFormat.GetMonth() - 1, 0, 11);
        FText MonthText = GetMonth(MonthIndex);

        FNumberFormattingOptions options = FNumberFormattingOptions();
        options.SetUseGrouping(false);
        FText DayText = FText::AsNumber(DateToFormat.GetDay(), options);
        FText YearText = FText::AsNumber(DateToFormat.GetYear(), options);

        FText FormatPattern = NSLOCTEXT("SpaceTradersDate", "DateFormatPattern", "{0} {1} {2}");

        return FText::Format(FormatPattern, DayText, MonthText, YearText);
    }
}