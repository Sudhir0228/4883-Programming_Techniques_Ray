SET TAB OFF
SET SQLBLANKLINES ON
SET LINESIZE 180
SET PAGESIZE 100

-- ============================================================
-- Query 1: Inventory alert report
--
-- English:
-- Which variants are out of stock, at or below their reorder
-- threshold, or at risk of stockout based on recent sales
-- velocity and their supplier's standard lead time?
--
-- Business Goal: 8
--
-- Techniques:
-- Multiple JOINs, subqueries, CASE, SUM,
-- GROUP BY, calculated columns, ORDER BY.
--
-- Previous 30 complete calendar days are used.
-- NULL inventory cover means no observed recent sales.
--
-- For historical sample-data demonstration, replace
-- TRUNC(SYSDATE) with DATE '2026-09-01' below.
-- Disclose that this is a historical simulation.
-- ============================================================

PROMPT
PROMPT ===== QUERY 1: INVENTORY ALERT REPORT =====

SELECT
    VariantID,
    ProductName,
    SupplierName,
    AvailableStock,
    ReorderThreshold,
    UnitsLast30,
    ROUND(UnitsLast30 / 30, 3) AS DailySalesVelocity,
    ROUND(DaysCover, 2) AS DaysInventoryCover,
    StandardLeadTime,
    CASE
        WHEN AvailableStock = 0
            THEN 'OUT OF STOCK'
        WHEN AvailableStock <= ReorderThreshold
         AND DaysCover <= StandardLeadTime
            THEN 'REORDER AND STOCKOUT RISK'
        WHEN AvailableStock <= ReorderThreshold
            THEN 'REORDER NEEDED'
        ELSE 'STOCKOUT RISK'
    END AS StockStatus
FROM (
    SELECT
        pv.VariantID,
        p.ProductName,
        s.SupplierName,
        i.PhysicalQuantity - i.AllocatedQuantity
            AS AvailableStock,
        i.ReorderThreshold,
        s.StandardLeadTime,
        NVL(RecentUnitsSold, 0) AS UnitsLast30,
        (i.PhysicalQuantity - i.AllocatedQuantity) * 30
            / NULLIF(RecentUnitsSold, 0) AS DaysCover
    FROM F26_S001_T5_INVENTORY i
    JOIN F26_S001_T5_PRODUCT_VARIANT pv
        ON pv.VariantID = i.VariantID
    JOIN F26_S001_T5_PRODUCT p
        ON p.ProductID = pv.ProductID
    JOIN F26_S001_T5_SUPPLIER s
        ON s.SupplierID = pv.SupplierID
    LEFT JOIN (
        SELECT
            oi.VariantID AS RecentSalesVariantID,
            SUM(oi.Quantity) AS RecentUnitsSold
        FROM F26_S001_T5_ORDER_ITEM oi
        JOIN F26_S001_T5_AMAZON_ORDER ao
            ON ao.OrderNumber = oi.OrderNumber
        WHERE ao.OrderDate >= TRUNC(SYSDATE) - 30
          AND ao.OrderDate < TRUNC(SYSDATE)
        GROUP BY oi.VariantID
    )
        ON RecentSalesVariantID = pv.VariantID
)
WHERE AvailableStock = 0
   OR AvailableStock <= ReorderThreshold
   OR DaysCover <= StandardLeadTime
ORDER BY AvailableStock, VariantID;

-- Expected output:
-- One row per alerted variant.
-- Add actual Oracle output after testing.

-- ============================================================
-- Query 2: Consolidated profitability report
--
-- English:
-- What are sales, wholesale costs, Amazon fees, shipping,
-- refunds, estimated contribution, margins, and return rates
-- by variant, brand, and monthly category?
--
-- Business Goals: 1, 7, 11
--
-- Techniques:
-- Multiple JOINs, subqueries, GROUP BY, HAVING,
-- aggregates, GROUPING SETS, GROUPING, CASE, OVER.
--
-- Wholesale cost uses all Received purchase orders,
-- net of total purchase-line discounts.
-- This is an all-history reporting estimate.
--
-- Order fees and shipping are allocated by net sales share.
-- Zero-value orders use quantity share instead.
--
-- Returns are assigned to their original sale cohort.
-- Shared overhead and salaries are excluded.
-- Returned-inventory recovery value is not available.
--
-- Missing required costs make contribution and margin NULL.
-- Return rates measure returned order lines, not units.
-- Reporting levels overlap: do not sum them together.
-- ============================================================

PROMPT
PROMPT ===== QUERY 2: CONSOLIDATED PROFITABILITY REPORT =====

SELECT
    CASE
        WHEN GROUPING(VariantID) = 0
            THEN 'VARIANT'
        WHEN GROUPING(SalesMonth) = 0
            THEN 'MONTHLY CATEGORY'
        ELSE 'BRAND'
    END AS ReportLevel,
    TO_CHAR(SalesMonth, 'YYYY-MM') AS SalesMonth,
    Category,
    Brand,
    VariantID,
    ProductName,
    VariantSize,
    Color,
    COUNT(DISTINCT OrderNumber) AS TotalOrders,
    SUM(Quantity) AS UnitsSold,
    ROUND(SUM(NetSales), 2) AS NetSales,
    CASE
        WHEN COUNT(WholesaleCost) = COUNT(*)
            THEN ROUND(SUM(WholesaleCost), 2)
    END AS WholesaleCost,
    CASE
        WHEN COUNT(ReferralCost) = COUNT(*)
         AND COUNT(SubscriptionCost) = COUNT(*)
            THEN ROUND(
                SUM(ReferralCost + SubscriptionCost),
                2
            )
    END AS AmazonFees,
    CASE
        WHEN COUNT(ShippingCost) = COUNT(*)
            THEN ROUND(SUM(ShippingCost), 2)
    END AS ShippingCost,
    ROUND(SUM(Refunds), 2) AS ReturnRefunds,
    ROUND(SUM(ReturnShipping), 2) AS ReturnShipping,
    COUNT(*) AS SoldLines,
    SUM(ReturnedLine) AS ReturnedLines,
    ROUND(
        100 * SUM(ReturnedLine) / COUNT(*),
        2
    ) AS LineReturnRatePct,
    SUM(MissingCostLine) AS MissingCostLines,
    CASE
        WHEN SUM(MissingCostLine) = 0
            THEN ROUND(
                SUM(
                    NetSales - WholesaleCost
                    - ReferralCost - SubscriptionCost
                    - ShippingCost - Refunds - ReturnShipping
                ),
                2
            )
    END AS EstimatedNetContribution,
    CASE
        WHEN SUM(MissingCostLine) = 0
            THEN ROUND(
                100 * SUM(
                    NetSales - WholesaleCost
                    - ReferralCost - SubscriptionCost
                    - ShippingCost - Refunds - ReturnShipping
                ) / NULLIF(SUM(NetSales), 0),
                2
            )
    END AS ContributionMarginPct
FROM (
    SELECT
        SalesMonth,
        Category,
        Brand,
        VariantID,
        ProductName,
        VariantSize,
        Color,
        OrderNumber,
        Quantity,
        NetSales,
        WholesaleCost,
        AllocationShare * OrderReferralCost AS ReferralCost,
        AllocationShare * OrderSubscriptionCost
            AS SubscriptionCost,
        AllocationShare * OrderShippingCost AS ShippingCost,
        Refunds,
        ReturnShipping,
        ReturnedLine,
        MissingCostLine
    FROM (
        SELECT
            TRUNC(ao.OrderDate, 'MM') AS SalesMonth,
            p.Category,
            p.Brand,
            pv.VariantID,
            p.ProductName,
            pv.VariantSize,
            pv.Color,
            oi.OrderNumber,
            oi.Quantity,
            oi.Quantity * oi.SellingPricePerUnit
                - oi.Discount AS NetSales,
            oi.Quantity * AverageUnitCost AS WholesaleCost,
            ao.AmazonReferralCost AS OrderReferralCost,
            ao.SubscriptionCost AS OrderSubscriptionCost,
            ao.ShippingCost AS OrderShippingCost,
            CASE
                WHEN SUM(
                    oi.Quantity * oi.SellingPricePerUnit
                    - oi.Discount
                ) OVER (
                    PARTITION BY oi.OrderNumber
                ) > 0
                THEN (
                    oi.Quantity * oi.SellingPricePerUnit
                    - oi.Discount
                ) / NULLIF(
                    SUM(
                        oi.Quantity * oi.SellingPricePerUnit
                        - oi.Discount
                    ) OVER (
                        PARTITION BY oi.OrderNumber
                    ),
                    0
                )
                ELSE oi.Quantity / SUM(oi.Quantity) OVER (
                    PARTITION BY oi.OrderNumber
                )
            END AS AllocationShare,
            NVL(r.RefundAmount, 0) AS Refunds,
            NVL(r.ReturnShippingCost, 0) AS ReturnShipping,
            CASE
                WHEN r.ReturnNumber IS NOT NULL THEN 1
                ELSE 0
            END AS ReturnedLine,
            CASE
                WHEN AverageUnitCost IS NULL
                  OR ao.AmazonReferralCost IS NULL
                  OR ao.SubscriptionCost IS NULL
                  OR ao.ShippingCost IS NULL
                    THEN 1
                ELSE 0
            END AS MissingCostLine
        FROM F26_S001_T5_ORDER_ITEM oi
        JOIN F26_S001_T5_AMAZON_ORDER ao
            ON ao.OrderNumber = oi.OrderNumber
        JOIN F26_S001_T5_PRODUCT_VARIANT pv
            ON pv.VariantID = oi.VariantID
        JOIN F26_S001_T5_PRODUCT p
            ON p.ProductID = pv.ProductID
        LEFT JOIN (
            SELECT
                pod.VariantID AS CostVariantID,
                SUM(
                    pod.OrderedQuantity * pod.CostPerUnit
                    - pod.Discount
                ) / SUM(pod.OrderedQuantity)
                    AS AverageUnitCost
            FROM F26_S001_T5_PURCHASE_ORDER_DETAIL pod
            JOIN F26_S001_T5_PURCHASE_ORDER po
                ON po.PurchaseOrderID = pod.PurchaseOrderID
            WHERE po.Status = 'Received'
            GROUP BY pod.VariantID
        )
            ON CostVariantID = oi.VariantID
        LEFT JOIN F26_S001_T5_RETURN r
            ON r.OrderNumber = oi.OrderNumber
           AND r.LineItemNumber = oi.LineItemNumber
    )
)
GROUP BY GROUPING SETS (
    (
        VariantID,
        ProductName,
        Brand,
        Category,
        VariantSize,
        Color
    ),
    (Brand),
    (SalesMonth, Category)
)
HAVING SUM(Quantity) > 0
ORDER BY
    ReportLevel,
    SalesMonth,
    Category,
    Brand,
    VariantID;

-- Expected output:
-- VARIANT, BRAND, and MONTHLY CATEGORY reporting levels.
-- NULL contribution with MissingCostLines > 0 means unknown.
-- Add actual Oracle output after testing.

-- ============================================================
-- Query 3: Complete return-reason breakdown
--
-- English:
-- How are all return reasons distributed within each category
-- and brand, and how many involve size or fit?
--
-- Business Goal: 3
--
-- Techniques:
-- Multiple JOINs, GROUP BY, HAVING, COUNT, SUM,
-- LIKE, CASE, OVER, ORDER BY.
--
-- All reasons are included.
-- LIKE identifies size/fit-related returns.
-- ============================================================

PROMPT
PROMPT ===== QUERY 3: RETURN-REASON BREAKDOWN =====

SELECT
    p.Category,
    p.Brand,
    NVL(r.Reason, 'Unspecified') AS ReturnReason,
    COUNT(r.ReturnNumber) AS ReturnCount,
    SUM(
        CASE
            WHEN LOWER(r.Reason) LIKE '%size%'
              OR LOWER(r.Reason) LIKE '%fit%'
                THEN 1
            ELSE 0
        END
    ) AS SizeFitReturnCount,
    ROUND(
        100 * COUNT(r.ReturnNumber)
        / SUM(COUNT(r.ReturnNumber)) OVER (
            PARTITION BY p.Category, p.Brand
        ),
        2
    ) AS ReasonPct,
    ROUND(SUM(r.RefundAmount), 2) AS TotalRefund,
    ROUND(SUM(r.ReturnShippingCost), 2) AS ReturnShipping
FROM F26_S001_T5_RETURN r
JOIN F26_S001_T5_ORDER_ITEM oi
    ON oi.OrderNumber = r.OrderNumber
   AND oi.LineItemNumber = r.LineItemNumber
JOIN F26_S001_T5_PRODUCT_VARIANT pv
    ON pv.VariantID = oi.VariantID
JOIN F26_S001_T5_PRODUCT p
    ON p.ProductID = pv.ProductID
GROUP BY
    p.Category,
    p.Brand,
    NVL(r.Reason, 'Unspecified')
HAVING COUNT(r.ReturnNumber) > 0
ORDER BY
    p.Category,
    p.Brand,
    ReturnCount DESC,
    ReturnReason;

-- Expected output:
-- All return reasons grouped by category and brand.
-- ReasonPct totals approximately 100 within category/brand.
-- Add actual Oracle output after testing.

-- ============================================================
-- Query 4: Monthly category sales with subtotals
--
-- English:
-- What are monthly category sales and quantities, including
-- monthly subtotals and a grand total across all months?
--
-- Business Goals: Supports 1 and 6
--
-- Techniques:
-- Multiple JOINs, ROLLUP, GROUPING, CASE,
-- SUM, GROUP BY, ORDER BY.
-- ============================================================

PROMPT
PROMPT ===== QUERY 4: MONTHLY CATEGORY SALES ROLLUP =====

COLUMN SalesMonth FORMAT A12
COLUMN CategoryLabel FORMAT A22

SELECT
    CASE
        WHEN GROUPING(TRUNC(ao.OrderDate, 'MM')) = 1
            THEN 'ALL MONTHS'
        ELSE TO_CHAR(
            TRUNC(ao.OrderDate, 'MM'),
            'YYYY-MM'
        )
    END AS SalesMonth,
    CASE
        WHEN GROUPING(TRUNC(ao.OrderDate, 'MM')) = 1
            THEN 'GRAND TOTAL'
        WHEN GROUPING(p.Category) = 1
            THEN 'MONTH TOTAL'
        ELSE p.Category
    END AS CategoryLabel,
    SUM(oi.Quantity) AS UnitsSold,
    ROUND(
        SUM(
            oi.Quantity * oi.SellingPricePerUnit
            - oi.Discount
        ),
        2
    ) AS NetRevenue
FROM F26_S001_T5_AMAZON_ORDER ao
JOIN F26_S001_T5_ORDER_ITEM oi
    ON ao.OrderNumber = oi.OrderNumber
JOIN F26_S001_T5_PRODUCT_VARIANT pv
    ON oi.VariantID = pv.VariantID
JOIN F26_S001_T5_PRODUCT p
    ON pv.ProductID = p.ProductID
GROUP BY ROLLUP (
    TRUNC(ao.OrderDate, 'MM'),
    p.Category
)
ORDER BY
    GROUPING(TRUNC(ao.OrderDate, 'MM')),
    TRUNC(ao.OrderDate, 'MM'),
    GROUPING(p.Category),
    p.Category;

-- Expected output:
-- Category rows, monthly subtotal rows, and a grand total.
-- Initial sample grand total: 90 units and 4658.40 revenue.
-- Retain or update your verified Oracle output here.

-- ============================================================
-- Query 5: Supplier purchase-history coverage
--
-- English:
-- Which suppliers have supplied every variant assigned to
-- them through at least one received purchase order issued
-- to that same supplier?
--
-- Business Goal: Supports 4
--
-- Techniques:
-- Relational division, correlated nested subqueries,
-- NOT EXISTS, EXISTS, JOIN, ORDER BY.
--
-- Suppliers without assigned variants are excluded.
-- ============================================================

PROMPT
PROMPT ===== QUERY 5: SUPPLIER VARIANT COVERAGE =====

SELECT
    s.SupplierID,
    s.SupplierName,
    s.Net30Status,
    s.CreditLimit
FROM F26_S001_T5_SUPPLIER s
WHERE EXISTS (
    SELECT 1
    FROM F26_S001_T5_PRODUCT_VARIANT pv
    WHERE pv.SupplierID = s.SupplierID
)
AND NOT EXISTS (
    SELECT 1
    FROM F26_S001_T5_PRODUCT_VARIANT pv
    WHERE pv.SupplierID = s.SupplierID
      AND NOT EXISTS (
          SELECT 1
          FROM F26_S001_T5_PURCHASE_ORDER po
          JOIN F26_S001_T5_PURCHASE_ORDER_DETAIL pod
              ON po.PurchaseOrderID = pod.PurchaseOrderID
          WHERE po.SupplierID = s.SupplierID
            AND po.Status = 'Received'
            AND pod.VariantID = pv.VariantID
      )
)
ORDER BY s.SupplierName, s.SupplierID;

-- Expected output:
-- Suppliers satisfying the "every assigned variant" condition.
-- Initial sample data produces 27 supplier rows.
-- Retain or update your verified Oracle output here.

-- ============================================================
-- Query 6: Monthly and seasonal best sellers
--
-- English:
-- Which variants rank in the top three by quantity or revenue
-- each month and season, and what proportion of period sales
-- does each variant generate?
--
-- Business Goal: 6
--
-- Techniques:
-- Multiple JOINs, UNION ALL, GROUP BY,
-- DENSE_RANK OVER, SUM OVER, nested subqueries.
--
-- Seasons:
-- Winter: December-February
-- Spring: March-May
-- Summer: June-August
-- Fall: September-November
--
-- PeriodStart identifies the first month of each season.
-- Ties can produce more than three qualifying variants.
-- ============================================================

PROMPT
PROMPT ===== QUERY 6: MONTHLY AND SEASONAL BEST SELLERS =====

SELECT
    PeriodType,
    TO_CHAR(PeriodStart, 'YYYY-MM') AS PeriodStart,
    VariantID,
    ProductName,
    UnitsSold,
    ROUND(NetRevenue, 2) AS NetRevenue,
    QuantityRank,
    RevenueRank,
    ROUND(RevenueSharePct, 2) AS RevenueSharePct
FROM (
    SELECT
        PeriodType,
        PeriodStart,
        VariantID,
        ProductName,
        UnitsSold,
        NetRevenue,
        DENSE_RANK() OVER (
            PARTITION BY PeriodType, PeriodStart
            ORDER BY UnitsSold DESC
        ) AS QuantityRank,
        DENSE_RANK() OVER (
            PARTITION BY PeriodType, PeriodStart
            ORDER BY NetRevenue DESC
        ) AS RevenueRank,
        100 * NetRevenue
        / NULLIF(
            SUM(NetRevenue) OVER (
                PARTITION BY PeriodType, PeriodStart
            ),
            0
        ) AS RevenueSharePct
    FROM (
        SELECT
            PeriodType,
            PeriodStart,
            VariantID,
            ProductName,
            SUM(Quantity) AS UnitsSold,
            SUM(LineSales) AS NetRevenue
        FROM (
            SELECT
                'MONTH' AS PeriodType,
                TRUNC(ao.OrderDate, 'MM') AS PeriodStart,
                pv.VariantID,
                p.ProductName,
                oi.Quantity,
                oi.Quantity * oi.SellingPricePerUnit
                    - oi.Discount AS LineSales
            FROM F26_S001_T5_AMAZON_ORDER ao
            JOIN F26_S001_T5_ORDER_ITEM oi
                ON oi.OrderNumber = ao.OrderNumber
            JOIN F26_S001_T5_PRODUCT_VARIANT pv
                ON pv.VariantID = oi.VariantID
            JOIN F26_S001_T5_PRODUCT p
                ON p.ProductID = pv.ProductID

            UNION ALL

            SELECT
                'SEASON',
                ADD_MONTHS(
                    TRUNC(ADD_MONTHS(ao.OrderDate, 1), 'Q'),
                    -1
                ),
                pv.VariantID,
                p.ProductName,
                oi.Quantity,
                oi.Quantity * oi.SellingPricePerUnit
                    - oi.Discount
            FROM F26_S001_T5_AMAZON_ORDER ao
            JOIN F26_S001_T5_ORDER_ITEM oi
                ON oi.OrderNumber = ao.OrderNumber
            JOIN F26_S001_T5_PRODUCT_VARIANT pv
                ON pv.VariantID = oi.VariantID
            JOIN F26_S001_T5_PRODUCT p
                ON p.ProductID = pv.ProductID
        )
        GROUP BY
            PeriodType,
            PeriodStart,
            VariantID,
            ProductName
    )
)
WHERE QuantityRank <= 3
   OR RevenueRank <= 3
ORDER BY
    PeriodType,
    PeriodStart,
    RevenueRank,
    QuantityRank,
    VariantID;

-- Expected output:
-- Monthly and seasonal rows with separate quantity/revenue ranks.
-- More than three rows can qualify because of ties.
-- Add actual Oracle output after testing.

-- ============================================================
-- Query 7: Product price similarity
--
-- English:
-- Which five variants have MSRP and selling-price
-- characteristics most similar to Variant 2001,
-- using reference prices of 19.99 and 17.99?
--
-- Business Goals:
-- Supplementary pricing analysis.
--
-- Techniques:
-- Multiple JOINs, VECTOR_DISTANCE, VECTOR, TO_VECTOR,
-- EUCLIDEAN, ORDER BY, FETCH FIRST.
--
-- Reference prices are fixed for this comparison.
-- Update them if the reference variant's prices change.
-- ============================================================

PROMPT
PROMPT ===== QUERY 7: PRODUCT PRICE SIMILARITY =====

COLUMN PriceDistance FORMAT 999990.00

SELECT
    pv.VariantID,
    p.ProductName,
    p.Category,
    p.MSRP,
    pv.SellingPrice,
    ROUND(
        VECTOR_DISTANCE(
            VECTOR('[19.99,17.99]'),
            TO_VECTOR(
                '['
                || TO_CHAR(
                    p.MSRP,
                    'FM999990D00',
                    'NLS_NUMERIC_CHARACTERS=''.,'''
                )
                || ','
                || TO_CHAR(
                    pv.SellingPrice,
                    'FM999990D00',
                    'NLS_NUMERIC_CHARACTERS=''.,'''
                )
                || ']'
            ),
            EUCLIDEAN
        ),
        2
    ) AS PriceDistance
FROM F26_S001_T5_PRODUCT_VARIANT pv
JOIN F26_S001_T5_PRODUCT p
    ON pv.ProductID = p.ProductID
WHERE pv.VariantID <> 2001
ORDER BY PriceDistance ASC, pv.VariantID
FETCH FIRST 5 ROWS ONLY;

-- Expected output, previously verified on Oracle Omega:
--
-- VariantID  ProductName             PriceDistance
-- 2033       Everyday Crew Socks     1.35
-- 2005       Ribbed Tank Top         4.04
-- 2034       Winter Knit Beanie      4.04
-- 2032       Seamless Briefs         6.73
-- 2042       Cotton Henley Shirt     9.42

-- ============================================================
-- Query 8: Supplier performance, credit, and savings
--
-- English:
-- How do suppliers compare on delivery performance, actual
-- lead time, returns, purchases, credit terms, and estimated
-- savings under a 3.5 percent Net 30 scenario?
--
-- Business Goals: 4 and 13
--
-- Techniques:
-- Multiple JOINs, aggregated subqueries, GROUP BY,
-- aggregates, CASE, calculated percentages.
--
-- Purchase and return data are aggregated separately
-- to avoid multiplying totals.
--
-- Return attribution uses the current primary supplier.
-- Current Net30Status does not prove historical eligibility.
-- Savings shown are estimates, not verified realized savings.
-- ============================================================

PROMPT
PROMPT ===== QUERY 8: SUPPLIER PERFORMANCE AND CREDIT =====

SELECT
    s.SupplierID,
    s.SupplierName,
    s.Net30Status,
    s.PaymentTerms,
    s.CreditLimit,
    s.StandardLeadTime,
    s.SavingsPercentage AS RecordedSavingsPct,
    3.5 AS ScenarioSavingsPct,
    NVL(TotalOrders, 0) AS TotalOrders,
    NVL(PurchaseHistory, 0) AS TotalOrderedValue,
    NVL(ReceivedValue, 0) AS ReceivedPurchaseValue,
    ROUND(AverageLeadDays, 2) AS AverageLeadDays,
    ROUND(
        100 * OnTimeOrders / NULLIF(AssessableOrders, 0),
        2
    ) AS OnTimePct,
    NVL(SoldLines, 0) AS SoldLines,
    NVL(ReturnedLines, 0) AS ReturnedLines,
    ROUND(
        100 * ReturnedLines / NULLIF(SoldLines, 0),
        2
    ) AS LineReturnRatePct,
    CASE
        WHEN s.Net30Status = 'Active'
            THEN ROUND(NVL(ReceivedValue, 0) * 0.035, 2)
        ELSE 0
    END AS EstimatedEligibleSavings,
    CASE
        WHEN s.Net30Status = 'Inactive'
            THEN ROUND(NVL(ReceivedValue, 0) * 0.035, 2)
        ELSE 0
    END AS PotentialAdditionalSavings,
    CAST(NULL AS NUMBER) AS VerifiedActualSavings
FROM F26_S001_T5_SUPPLIER s
LEFT JOIN (
    SELECT
        po.SupplierID AS PurchaseSupplierID,
        COUNT(*) AS TotalOrders,
        SUM(po.TotalCost) AS PurchaseHistory,
        SUM(
            CASE
                WHEN po.Status = 'Received'
                    THEN po.TotalCost
                ELSE 0
            END
        ) AS ReceivedValue,
        AVG(
            CASE
                WHEN po.Status = 'Received'
                    THEN po.DateReceived - po.DatePlaced
            END
        ) AS AverageLeadDays,
        SUM(
            CASE
                WHEN po.Status = 'Received'
                 AND po.EstimatedDeliveryDate IS NOT NULL
                    THEN 1
                ELSE 0
            END
        ) AS AssessableOrders,
        SUM(
            CASE
                WHEN po.Status = 'Received'
                 AND po.DateReceived <= po.EstimatedDeliveryDate
                    THEN 1
                ELSE 0
            END
        ) AS OnTimeOrders
    FROM F26_S001_T5_PURCHASE_ORDER po
    GROUP BY po.SupplierID
)
    ON PurchaseSupplierID = s.SupplierID
LEFT JOIN (
    SELECT
        pv.SupplierID AS ReturnSupplierID,
        COUNT(oi.LineItemNumber) AS SoldLines,
        COUNT(r.ReturnNumber) AS ReturnedLines
    FROM F26_S001_T5_PRODUCT_VARIANT pv
    LEFT JOIN F26_S001_T5_ORDER_ITEM oi
        ON oi.VariantID = pv.VariantID
    LEFT JOIN F26_S001_T5_RETURN r
        ON r.OrderNumber = oi.OrderNumber
       AND r.LineItemNumber = oi.LineItemNumber
    GROUP BY pv.SupplierID
)
    ON ReturnSupplierID = s.SupplierID
ORDER BY
    OnTimePct DESC NULLS LAST,
    s.SupplierName;

-- Expected output:
-- One row per supplier.
-- Unknown delivery percentages and actual savings remain NULL.
-- Add actual Oracle output after testing.

-- ============================================================
-- Query 9: Shipping cost and delivery analysis
--
-- English:
-- How do shipping costs and delivery performance compare
-- by carrier/service and within destination regions,
-- weight ranges, and recorded package dimensions?
--
-- Business Goal: 12
--
-- Techniques:
-- JOIN, GROUPING SETS, GROUPING, CASE,
-- aggregates, calculated percentages, ORDER BY.
--
-- Weight bands use the stored PackageWeight units.
-- Length is unavailable, so volume cannot be calculated.
-- All shipped orders contribute to shipping-cost averages.
-- On-time percentage uses delivered orders with known
-- expected delivery dates.
-- ============================================================

PROMPT
PROMPT ===== QUERY 9: SHIPPING COST AND DELIVERY ANALYSIS =====

SELECT
    CASE
        WHEN GROUPING(DestinationRegion) = 1
            THEN 'CARRIER/SERVICE'
        ELSE 'PACKAGE/REGION'
    END AS ReportLevel,
    ShippingCarrier,
    ShippingService,
    DestinationRegion,
    WeightBand,
    Width,
    Height,
    COUNT(*) AS ShippedOrders,
    ROUND(AVG(ShippingCost), 2) AS AverageShippingCost,
    ROUND(AVG(PackageWeight), 3) AS AverageWeight,
    ROUND(
        AVG(ActualDeliveryDate - ShippingDate),
        2
    ) AS AverageDeliveryDays,
    SUM(
        CASE
            WHEN ActualDeliveryDate IS NOT NULL THEN 1
            ELSE 0
        END
    ) AS DeliveredOrders,
    SUM(
        CASE
            WHEN ActualDeliveryDate <= ExpectedDate THEN 1
            ELSE 0
        END
    ) AS OnTimeOrders,
    SUM(
        CASE
            WHEN ActualDeliveryDate > ExpectedDate THEN 1
            ELSE 0
        END
    ) AS LateOrders,
    ROUND(
        100 * SUM(
            CASE
                WHEN ActualDeliveryDate <= ExpectedDate THEN 1
                ELSE 0
            END
        )
        / NULLIF(
            SUM(
                CASE
                    WHEN ActualDeliveryDate IS NOT NULL
                     AND ExpectedDate IS NOT NULL
                        THEN 1
                    ELSE 0
                END
            ),
            0
        ),
        2
    ) AS OnTimePct
FROM (
    SELECT
        ao.OrderNumber,
        ao.ShippingCarrier,
        ao.ShippingService,
        ao.DestinationRegion,
        ao.PackageWeight,
        ao.Width,
        ao.Height,
        ao.ShippingCost,
        ao.ShippingDate,
        ao.ExpectedDate,
        ao.ActualDeliveryDate,
        CASE
            WHEN ao.PackageWeight <= 1 THEN '01: <=1'
            WHEN ao.PackageWeight <= 2 THEN '02: >1 to 2'
            WHEN ao.PackageWeight <= 5 THEN '03: >2 to 5'
            ELSE '04: >5'
        END AS WeightBand
    FROM F26_S001_T5_AMAZON_ORDER ao
    JOIN F26_S001_T5_CUSTOMER c
        ON c.CustomerID = ao.CustomerID
    WHERE ao.ShippingDate IS NOT NULL
)
GROUP BY GROUPING SETS (
    (ShippingCarrier, ShippingService),
    (
        ShippingCarrier,
        ShippingService,
        DestinationRegion,
        WeightBand,
        Width,
        Height
    )
)
ORDER BY
    ReportLevel,
    ShippingCarrier,
    ShippingService,
    DestinationRegion,
    WeightBand,
    Width,
    Height;

-- Expected output:
-- Carrier/service summaries and package/region details.
-- Reporting levels overlap; do not sum them together.
-- Add actual Oracle output after testing.

-- ============================================================
-- Query 10: Return rates at multiple reporting levels
--
-- English:
-- What proportion of sold order lines have a recorded return,
-- broken down by variant, product, brand, and category?
-- Variant rows include size and color.
--
-- Business Goal: 2
--
-- Techniques:
-- Multiple JOINs, GROUPING SETS, GROUPING,
-- COUNT, CASE, calculated percentages.
--
-- Rate measures returned order lines, not returned units.
-- Unsold variants have a NULL rate.
-- ============================================================

PROMPT
PROMPT ===== QUERY 10: RETURN RATE ANALYSIS =====

SELECT
    CASE
        WHEN GROUPING(pv.VariantID) = 0 THEN 'VARIANT'
        WHEN GROUPING(p.ProductID) = 0 THEN 'PRODUCT'
        WHEN GROUPING(p.Brand) = 0 THEN 'BRAND'
        ELSE 'CATEGORY'
    END AS ReportLevel,
    p.Category,
    p.Brand,
    p.ProductID,
    p.ProductName,
    pv.VariantID,
    pv.VariantSize,
    pv.Color,
    COUNT(oi.LineItemNumber) AS SoldLines,
    COUNT(r.ReturnNumber) AS ReturnedLines,
    ROUND(
        100 * COUNT(r.ReturnNumber)
        / NULLIF(COUNT(oi.LineItemNumber), 0),
        2
    ) AS LineReturnRatePct
FROM F26_S001_T5_PRODUCT p
JOIN F26_S001_T5_PRODUCT_VARIANT pv
    ON pv.ProductID = p.ProductID
LEFT JOIN F26_S001_T5_ORDER_ITEM oi
    ON oi.VariantID = pv.VariantID
LEFT JOIN F26_S001_T5_RETURN r
    ON r.OrderNumber = oi.OrderNumber
   AND r.LineItemNumber = oi.LineItemNumber
GROUP BY GROUPING SETS (
    (
        p.Category,
        p.Brand,
        p.ProductID,
        p.ProductName,
        pv.VariantID,
        pv.VariantSize,
        pv.Color
    ),
    (
        p.Category,
        p.Brand,
        p.ProductID,
        p.ProductName
    ),
    (p.Brand),
    (p.Category)
)
ORDER BY
    ReportLevel,
    p.Category,
    p.Brand,
    p.ProductID,
    pv.VariantID;

-- Expected output:
-- VARIANT, PRODUCT, BRAND, and CATEGORY rows.
-- Rates are recomputed from counts at each level.
-- Add actual Oracle output after testing.

-- ============================================================
-- Query 11: Monthly profit and loss estimate
--
-- English:
-- What are monthly sales, wholesale costs, Amazon fees,
-- outbound shipping, refunds, return shipping, operating
-- expenses, estimated salaries, and profit or loss?
--
-- Business Goal: 9
--
-- Techniques:
-- Multiple JOINs, subqueries, calendar generation,
-- GROUP BY, aggregates, CASE.
--
-- Sales and direct sale costs use the order month.
-- Refunds and return shipping use the return month.
-- Operating expenses use ExpenseDate.
--
-- Salary is annual, divided by 12.
-- Hire-month salary is prorated by calendar days.
-- Salary changes and employee departures are not tracked.
--
-- Wholesale costs use all Received purchase orders.
-- Returned-inventory recovery is not valued.
--
-- Operating expenses must exclude costs counted elsewhere.
-- Recurring expenses require stored rows when incurred.
-- ============================================================

PROMPT
PROMPT ===== QUERY 11: MONTHLY PROFIT AND LOSS =====

SELECT
    TO_CHAR(ReportMonth, 'YYYY-MM') AS ReportMonth,
    NetSales,
    WholesaleCost,
    AmazonFees,
    ShippingCost,
    ReturnRefunds,
    ReturnShipping,
    OperatingCosts,
    ROUND(EstimatedSalaries, 2) AS EstimatedSalaries,
    MissingCostLines,
    MissingCostOrders,
    CASE
        WHEN MissingCostLines = 0
         AND MissingCostOrders = 0
            THEN ROUND(
                NetSales - WholesaleCost
                - AmazonFees - ShippingCost
                - ReturnRefunds - ReturnShipping
                - OperatingCosts - EstimatedSalaries,
                2
            )
    END AS EstimatedProfitLoss
FROM (
    SELECT
        ReportMonth,
        ROUND(NVL(MonthlyNetSales, 0), 2) AS NetSales,
        CASE
            WHEN NVL(UnknownWholesaleLines, 0) = 0
                THEN ROUND(NVL(MonthlyWholesaleCost, 0), 2)
        END AS WholesaleCost,
        CASE
            WHEN NVL(UnknownOrderCosts, 0) = 0
                THEN ROUND(NVL(MonthlyAmazonFees, 0), 2)
        END AS AmazonFees,
        CASE
            WHEN NVL(UnknownOrderCosts, 0) = 0
                THEN ROUND(NVL(MonthlyShippingCost, 0), 2)
        END AS ShippingCost,
        ROUND(NVL(MonthlyRefunds, 0), 2) AS ReturnRefunds,
        ROUND(NVL(MonthlyReturnShipping, 0), 2)
            AS ReturnShipping,
        ROUND(NVL(MonthlyOperatingCosts, 0), 2)
            AS OperatingCosts,
        NVL(UnknownWholesaleLines, 0) AS MissingCostLines,
        NVL(UnknownOrderCosts, 0) AS MissingCostOrders,
        NVL(
            (
                SELECT
                    SUM(
                        e.Salary / 12
                        * (
                            LAST_DAY(ReportMonth)
                            - GREATEST(
                                TRUNC(e.HireDate),
                                ReportMonth
                            )
                            + 1
                        )
                        / (
                            LAST_DAY(ReportMonth)
                            - ReportMonth
                            + 1
                        )
                    )
                FROM F26_S001_T5_EMPLOYEE e
                WHERE e.HireDate < ADD_MONTHS(ReportMonth, 1)
            ),
            0
        ) AS EstimatedSalaries
    FROM (
        SELECT
            ADD_MONTHS(FirstMonth, LEVEL - 1) AS ReportMonth
        FROM (
            SELECT
                MIN(EventMonth) AS FirstMonth,
                MAX(EventMonth) AS LastMonth
            FROM (
                SELECT
                    TRUNC(OrderDate, 'MM') AS EventMonth
                FROM F26_S001_T5_AMAZON_ORDER

                UNION

                SELECT TRUNC(ReturnDate, 'MM')
                FROM F26_S001_T5_RETURN

                UNION

                SELECT TRUNC(ExpenseDate, 'MM')
                FROM F26_S001_T5_OPERATING_COST
            )
        )
        WHERE FirstMonth IS NOT NULL
        CONNECT BY LEVEL <=
            MONTHS_BETWEEN(LastMonth, FirstMonth) + 1
    )
    LEFT JOIN (
        SELECT
            TRUNC(ao.OrderDate, 'MM') AS SalesMonth,
            SUM(
                oi.Quantity * oi.SellingPricePerUnit
                - oi.Discount
            ) AS MonthlyNetSales,
            SUM(
                oi.Quantity * AverageUnitCost
            ) AS MonthlyWholesaleCost,
            SUM(
                CASE
                    WHEN AverageUnitCost IS NULL THEN 1
                    ELSE 0
                END
            ) AS UnknownWholesaleLines
        FROM F26_S001_T5_AMAZON_ORDER ao
        JOIN F26_S001_T5_ORDER_ITEM oi
            ON oi.OrderNumber = ao.OrderNumber
        LEFT JOIN (
            SELECT
                pod.VariantID AS CostVariantID,
                SUM(
                    pod.OrderedQuantity * pod.CostPerUnit
                    - pod.Discount
                ) / SUM(pod.OrderedQuantity)
                    AS AverageUnitCost
            FROM F26_S001_T5_PURCHASE_ORDER_DETAIL pod
            JOIN F26_S001_T5_PURCHASE_ORDER po
                ON po.PurchaseOrderID = pod.PurchaseOrderID
            WHERE po.Status = 'Received'
            GROUP BY pod.VariantID
        )
            ON CostVariantID = oi.VariantID
        GROUP BY TRUNC(ao.OrderDate, 'MM')
    )
        ON SalesMonth = ReportMonth
    LEFT JOIN (
        SELECT
            TRUNC(OrderDate, 'MM') AS FeeMonth,
            SUM(AmazonReferralCost + SubscriptionCost)
                AS MonthlyAmazonFees,
            SUM(ShippingCost) AS MonthlyShippingCost,
            SUM(
                CASE
                    WHEN AmazonReferralCost IS NULL
                      OR SubscriptionCost IS NULL
                      OR ShippingCost IS NULL
                        THEN 1
                    ELSE 0
                END
            ) AS UnknownOrderCosts
        FROM F26_S001_T5_AMAZON_ORDER
        GROUP BY TRUNC(OrderDate, 'MM')
    )
        ON FeeMonth = ReportMonth
    LEFT JOIN (
        SELECT
            TRUNC(ReturnDate, 'MM') AS RefundMonth,
            SUM(RefundAmount) AS MonthlyRefunds,
            SUM(ReturnShippingCost) AS MonthlyReturnShipping
        FROM F26_S001_T5_RETURN
        GROUP BY TRUNC(ReturnDate, 'MM')
    )
        ON RefundMonth = ReportMonth
    LEFT JOIN (
        SELECT
            TRUNC(ExpenseDate, 'MM') AS ExpenseMonth,
            SUM(Amount) AS MonthlyOperatingCosts
        FROM F26_S001_T5_OPERATING_COST
        GROUP BY TRUNC(ExpenseDate, 'MM')
    )
        ON ExpenseMonth = ReportMonth
)
ORDER BY ReportMonth;

-- Expected output:
-- Consecutive months covering recorded business events.
-- Missing required costs make estimated profit/loss NULL.
-- Add actual Oracle output after testing.

-- ============================================================
-- Query 12: Seasonal demand history and forecasting
--
-- English:
-- What are historical monthly variant sales, and what demand
-- is projected for the next twelve months using average sales
-- from comparable calendar months in earlier years?
-- What are the totals for complete three-month seasons?
--
-- Business Goal: 5
--
-- Techniques:
-- Multiple JOINs, subqueries, GROUP BY, UNION ALL,
-- calendar generation, CASE, OVER.
--
-- Forecast starts after the latest stored sales month.
-- Method: average observed same-month prior-year sales.
-- No growth factor is assumed.
--
-- Included historical months are assumed completely loaded.
-- Missing months are unknown, not automatically zero sales.
-- Missing comparable history produces NULL forecasts.
--
-- Seasonal totals require three known component months.
-- ============================================================

PROMPT
PROMPT ===== QUERY 12: SEASONAL DEMAND FORECASTING =====

SELECT
    ReportType,
    VariantID,
    ProductName,
    TO_CHAR(ReportMonth, 'YYYY-MM') AS ReportMonth,
    TO_CHAR(SeasonStart, 'YYYY-MM') AS SeasonStart,
    ActualUnits,
    ROUND(ForecastUnits, 2) AS ForecastUnits,
    PriorYearsUsed,
    CASE
        WHEN ReportType = 'HISTORY'
            THEN 'OBSERVED'
        WHEN PriorYearsUsed = 0
            THEN 'INSUFFICIENT HISTORY'
        WHEN PriorYearsUsed = 1
            THEN 'ONE-YEAR BASELINE'
        ELSE 'MULTI-YEAR BASELINE'
    END AS DataStatus,
    CASE
        WHEN COUNT(ActualUnits) OVER (
            PARTITION BY ReportType, VariantID, SeasonStart
        ) = 3
            THEN SUM(ActualUnits) OVER (
                PARTITION BY
                    ReportType,
                    VariantID,
                    SeasonStart
            )
    END AS ActualSeasonUnits,
    CASE
        WHEN COUNT(ForecastUnits) OVER (
            PARTITION BY ReportType, VariantID, SeasonStart
        ) = 3
            THEN ROUND(
                SUM(ForecastUnits) OVER (
                    PARTITION BY
                        ReportType,
                        VariantID,
                        SeasonStart
                ),
                2
            )
    END AS ForecastSeasonUnits
FROM (
    SELECT
        ReportType,
        pv.VariantID,
        p.ProductName,
        ReportMonth,
        ActualUnits,
        ForecastUnits,
        PriorYearsUsed,
        ADD_MONTHS(
            TRUNC(ADD_MONTHS(ReportMonth, 1), 'Q'),
            -1
        ) AS SeasonStart
    FROM (
        SELECT
            'HISTORY' AS ReportType,
            oi.VariantID AS ReportVariantID,
            TRUNC(ao.OrderDate, 'MM') AS ReportMonth,
            SUM(oi.Quantity) AS ActualUnits,
            CAST(NULL AS NUMBER) AS ForecastUnits,
            CAST(NULL AS NUMBER) AS PriorYearsUsed
        FROM F26_S001_T5_ORDER_ITEM oi
        JOIN F26_S001_T5_AMAZON_ORDER ao
            ON ao.OrderNumber = oi.OrderNumber
        GROUP BY
            oi.VariantID,
            TRUNC(ao.OrderDate, 'MM')

        UNION ALL

        SELECT
            'FORECAST',
            pv.VariantID,
            TargetMonth,
            CAST(NULL AS NUMBER),
            AVG(HistoricalUnits),
            COUNT(HistoricalMonth)
        FROM F26_S001_T5_PRODUCT_VARIANT pv
        CROSS JOIN (
            SELECT
                ADD_MONTHS(
                    FirstForecastMonth,
                    LEVEL - 1
                ) AS TargetMonth
            FROM (
                SELECT
                    ADD_MONTHS(
                        TRUNC(MAX(OrderDate), 'MM'),
                        1
                    ) AS FirstForecastMonth
                FROM F26_S001_T5_AMAZON_ORDER
            )
            WHERE FirstForecastMonth IS NOT NULL
            CONNECT BY LEVEL <= 12
        )
        LEFT JOIN (
            SELECT
                oi.VariantID AS HistoryVariantID,
                TRUNC(ao.OrderDate, 'MM') AS HistoricalMonth,
                SUM(oi.Quantity) AS HistoricalUnits
            FROM F26_S001_T5_ORDER_ITEM oi
            JOIN F26_S001_T5_AMAZON_ORDER ao
                ON ao.OrderNumber = oi.OrderNumber
            GROUP BY
                oi.VariantID,
                TRUNC(ao.OrderDate, 'MM')
        )
            ON HistoryVariantID = pv.VariantID
           AND EXTRACT(MONTH FROM HistoricalMonth)
               = EXTRACT(MONTH FROM TargetMonth)
           AND EXTRACT(YEAR FROM HistoricalMonth)
               < EXTRACT(YEAR FROM TargetMonth)
        GROUP BY pv.VariantID, TargetMonth
    )
    JOIN F26_S001_T5_PRODUCT_VARIANT pv
        ON pv.VariantID = ReportVariantID
    JOIN F26_S001_T5_PRODUCT p
        ON p.ProductID = pv.ProductID
)
ORDER BY
    ReportType,
    ReportMonth,
    VariantID;

-- Expected output:
-- Historical rows plus twelve future rows per variant.
-- Limited history produces some NULL forecasts.
-- Season totals repeat across component months:
-- do not sum those repeated totals again.
-- Add actual Oracle output after testing.

-- ============================================================
-- Query 13: Customer purchase behavior
--
-- English:
-- What are average order value, single-versus-multiple-variant
-- purchasing patterns, and repeat purchase rates for each
-- purchasing customer and for the business overall?
--
-- Business Goal: 10
--
-- Techniques:
-- Multiple JOINs, subqueries, GROUPING SETS,
-- CASE, aggregates, calculated percentages.
--
-- A single-product order means one distinct purchased variant.
-- Two units of one variant remain a single-variant order.
--
-- Repeat rate denominator is customers with at least one order.
-- Order value is calculated from lines after discounts.
-- ============================================================

PROMPT
PROMPT ===== QUERY 13: CUSTOMER PURCHASE BEHAVIOR =====

SELECT
    CASE
        WHEN GROUPING(CustomerID) = 1 THEN 'ALL BUYERS'
        ELSE 'CUSTOMER'
    END AS ReportLevel,
    CustomerID,
    Fname,
    Lname,
    COUNT(*) AS PurchasingCustomers,
    SUM(OrderCount) AS TotalOrders,
    ROUND(
        SUM(Revenue) / NULLIF(SUM(OrderCount), 0),
        2
    ) AS AverageOrderValue,
    SUM(SingleOrders) AS SingleVariantOrders,
    SUM(MultiOrders) AS MultiVariantOrders,
    ROUND(
        100 * SUM(SingleOrders)
        / NULLIF(SUM(OrderCount), 0),
        2
    ) AS SingleVariantOrderPct,
    ROUND(
        100 * SUM(MultiOrders)
        / NULLIF(SUM(OrderCount), 0),
        2
    ) AS MultiVariantOrderPct,
    SUM(
        CASE
            WHEN OrderCount > 1 THEN 1
            ELSE 0
        END
    ) AS RepeatCustomers,
    ROUND(
        100 * SUM(
            CASE
                WHEN OrderCount > 1 THEN 1
                ELSE 0
            END
        ) / NULLIF(COUNT(*), 0),
        2
    ) AS RepeatCustomerPct
FROM (
    SELECT
        c.CustomerID,
        c.Fname,
        c.Lname,
        COUNT(*) AS OrderCount,
        SUM(OrderValue) AS Revenue,
        SUM(
            CASE
                WHEN DistinctVariants = 1 THEN 1
                ELSE 0
            END
        ) AS SingleOrders,
        SUM(
            CASE
                WHEN DistinctVariants > 1 THEN 1
                ELSE 0
            END
        ) AS MultiOrders
    FROM F26_S001_T5_CUSTOMER c
    JOIN (
        SELECT
            ao.OrderNumber,
            ao.CustomerID AS OrderCustomerID,
            COUNT(DISTINCT oi.VariantID) AS DistinctVariants,
            SUM(
                oi.Quantity * oi.SellingPricePerUnit
                - oi.Discount
            ) AS OrderValue
        FROM F26_S001_T5_AMAZON_ORDER ao
        JOIN F26_S001_T5_ORDER_ITEM oi
            ON oi.OrderNumber = ao.OrderNumber
        GROUP BY ao.OrderNumber, ao.CustomerID
    )
        ON OrderCustomerID = c.CustomerID
    GROUP BY c.CustomerID, c.Fname, c.Lname
)
GROUP BY GROUPING SETS (
    (CustomerID, Fname, Lname),
    ()
)
ORDER BY ReportLevel, CustomerID;

-- Expected output:
-- Customer-level rows and one ALL BUYERS summary.
-- Customers with one order are not repeat customers.
-- Add actual Oracle output after testing.
