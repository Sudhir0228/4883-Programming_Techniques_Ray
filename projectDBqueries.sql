SET TAB OFF
SET SQLBLANKLINES ON
SET DEFINE OFF
SET LINESIZE 300
SET PAGESIZE 100
SET NUMWIDTH 12
SET NULL 'NULL'

-- ============================================================
-- Query 1: Complete inventory alert report
--
-- Business question:
-- Which variants are out of stock, at or below their reorder
-- threshold, or at risk of stockout because their inventory
-- cover is no greater than their supplier's standard lead time?
--
-- Business Goal: 8
--
-- Features:
-- Multiple JOINs, subqueries, CASE, SUM,
-- GROUP BY, calculated columns, ORDER BY.
--
-- Sales velocity uses the previous 30 complete calendar days.
-- NULL inventory cover means no observed recent sales.
-- ============================================================

COLUMN ProductName FORMAT A25
COLUMN SupplierName FORMAT A30
COLUMN StockStatus FORMAT A28
COLUMN DailySalesVelocity FORMAT 999990.000
COLUMN DaysInventoryCover FORMAT 999990.00

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

-- Expected output (verified in Oracle Omega):
--
-- VariantID | ProductName             | SupplierName               | AvailableStock | ReorderThreshold | UnitsLast30 | DailySalesVelocity | DaysInventoryCover | StandardLeadTime | StockStatus
-- 2012      | Formal Wrap Dress       | Silverline Clothing Supply | 20             | 25               | 0           | 0.000              | NULL               | 17               | REORDER NEEDED
-- 2024      | Training Track Jacket   | Canyon Apparel Supply      | 20             | 35               | 0           | 0.000              | NULL               | 13               | REORDER NEEDED
-- 2036      | Linen Button-Up Shirt   | Brightline Textile Group   | 20             | 20               | 0           | 0.000              | NULL               | 9                | REORDER NEEDED
-- 2001      | Classic Cotton T-Shirt  | Pacific Cotton Textiles    | 27             | 30               | 0           | 0.000              | NULL               | 6                | REORDER NEEDED
-- 2013      | Knit Sweater Dress      | Oakwood Fashion Distributors | 27           | 30               | 0           | 0.000              | NULL               | 18               | REORDER NEEDED
-- 2014      | Maxi Evening Dress      | Metro Garment Wholesale    | 34             | 35               | 0           | 0.000              | NULL               | 19               | REORDER NEEDED
--
-- 6 rows selected.

-- ============================================================
-- Query 2: Monthly profitability by product category
--
-- Business question:
-- Which product categories are profitable each month after
-- wholesale costs, Amazon fees, outbound shipping,
-- customer refunds, and return-shipping costs?
--
-- Business Goal: 1
--
-- Features:
-- Multiple JOINs, subqueries, GROUP BY, HAVING,
-- SUM, COUNT, CASE, OVER, calculated columns, ORDER BY.
--
-- Cost calculation:
-- Wholesale cost uses the weighted-average unit cost from
-- Received purchase orders, net of purchase-line discounts.
-- Purchase discounts are total monetary amounts per line.
-- This all-history average is a reporting estimate, not a
-- historical inventory-valuation ledger.
--
-- Order fees and outbound shipping are allocated to lines
-- according to their proportion of the order's net sales.
-- Zero-value orders use quantity share instead.
-- Stored SubscriptionCost is assumed already correctly
-- allocated to each order from the monthly subscription fee.
--
-- Return treatment:
-- RefundAmount is assumed to be the actual refund after
-- deducting any restocking fee. The fee is not deducted again.
-- Returns are attributed to the original sale month, even
-- when processed later.
-- Returned-inventory recovery value is not recorded.
--
-- Profit scope:
-- EstimatedNetContribution is after the listed direct costs,
-- but before shared operating expenses and employee salaries.
-- Those expenses are included separately in the monthly P&L.
--
-- Data limitation:
-- Some sold variants have no acquisition-cost records from
-- Received purchase orders. This may represent opening
-- inventory whose purchase-cost history was not imported.
--
-- Pending and Shipped purchase orders remain valid records,
-- but are excluded from the completed-purchase cost average.
-- A pending replenishment order does not cause missing cost
-- if an earlier Received purchase provides a known cost.
--
-- If any sold line lacks a known wholesale cost, the group's
-- WholesaleCost and EstimatedNetContribution are shown as NULL.
-- Missing order fees or shipping also prevent a complete
-- contribution calculation.
-- MissingCostLines counts lines with any required cost missing.
-- Unknown costs are not treated as zero.
--
-- All categories with sales are included.
-- ============================================================

PROMPT
PROMPT ===== QUERY 2: MONTHLY CATEGORY PROFITABILITY =====

COLUMN SalesMonth FORMAT A10
COLUMN Category FORMAT A15
COLUMN TotalOrders FORMAT 999990
COLUMN UnitsSold FORMAT 999990
COLUMN NetSales FORMAT 999999990.00
COLUMN WholesaleCost FORMAT 999999990.00
COLUMN AmazonFees FORMAT 9999990.00
COLUMN ShippingCost FORMAT 9999990.00
COLUMN ReturnRefunds FORMAT 999999990.00
COLUMN ReturnShipping FORMAT 9999990.00
COLUMN MissingCostLines FORMAT 999990
COLUMN EstimatedNetContribution FORMAT 999999990.00

SELECT
    TO_CHAR(SalesMonth, 'YYYY-MM') AS SalesMonth,
    Category,
    COUNT(DISTINCT OrderNumber) AS TotalOrders,
    SUM(Quantity) AS UnitsSold,
    ROUND(SUM(NetSales), 2) AS NetSales,
    CASE
        WHEN COUNT(LineWholesaleCost) = COUNT(*)
            THEN ROUND(SUM(LineWholesaleCost), 2)
    END AS WholesaleCost,
    CASE
        WHEN COUNT(LineAmazonFees) = COUNT(*)
            THEN ROUND(SUM(LineAmazonFees), 2)
    END AS AmazonFees,
    CASE
        WHEN COUNT(LineShippingCost) = COUNT(*)
            THEN ROUND(SUM(LineShippingCost), 2)
    END AS ShippingCost,
    ROUND(SUM(LineRefund), 2) AS ReturnRefunds,
    ROUND(SUM(LineReturnShipping), 2) AS ReturnShipping,
    SUM(MissingCostLine) AS MissingCostLines,
    CASE
        WHEN SUM(MissingCostLine) = 0
            THEN ROUND(
                SUM(
                    NetSales
                    - LineWholesaleCost
                    - LineAmazonFees
                    - LineShippingCost
                    - LineRefund
                    - LineReturnShipping
                ),
                2
            )
    END AS EstimatedNetContribution
FROM (
    SELECT
        SalesMonth,
        Category,
        OrderNumber,
        Quantity,
        NetSales,
        LineWholesaleCost,
        AllocationShare * OrderAmazonFees AS LineAmazonFees,
        AllocationShare * OrderShippingCost AS LineShippingCost,
        LineRefund,
        LineReturnShipping,
        MissingCostLine
    FROM (
        SELECT
            TRUNC(ao.OrderDate, 'MM') AS SalesMonth,
            p.Category,
            oi.OrderNumber,
            oi.Quantity,
            oi.Quantity * oi.SellingPricePerUnit
                - oi.Discount AS NetSales,
            oi.Quantity * AverageUnitCost AS LineWholesaleCost,
            ao.AmazonReferralCost + ao.SubscriptionCost
                AS OrderAmazonFees,
            ao.ShippingCost AS OrderShippingCost,
            NVL(r.RefundAmount, 0) AS LineRefund,
            NVL(r.ReturnShippingCost, 0) AS LineReturnShipping,
            CASE
                WHEN AverageUnitCost IS NULL
                  OR ao.AmazonReferralCost IS NULL
                  OR ao.SubscriptionCost IS NULL
                  OR ao.ShippingCost IS NULL
                    THEN 1
                ELSE 0
            END AS MissingCostLine,
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
            END AS AllocationShare
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
GROUP BY SalesMonth, Category
HAVING SUM(Quantity) > 0
ORDER BY SalesMonth, Category;

-- Expected output (verified in Oracle Omega):
--
-- SalesMonth | Category    | TotalOrders | UnitsSold | NetSales | WholesaleCost | AmazonFees | ShippingCost | ReturnRefunds | ReturnShipping | MissingCostLines | EstimatedNetContribution
-- 2026-03    | Bottoms     | 3           | 6         | 241.14   | 170.00        | 39.15      | 24.97        | 236.14        | 9.98           | 0                | -239.10
-- 2026-03    | Tops        | 5           | 11        | 293.29   | NULL          | 48.95      | 38.95        | 283.29        | 19.96          | 2                | NULL
-- 2026-04    | Bottoms     | 2           | 3         | 112.47   | NULL          | 18.85      | 15.98        | 109.97        | 4.99           | 2                | NULL
-- 2026-04    | Dresses     | 5           | 10        | 575.00   | NULL          | 91.21      | 42.95        | 562.50        | 24.95          | 2                | NULL
-- 2026-04    | Outerwear   | 1           | 2         | 134.98   | 40.00         | 21.24      | 4.99         | 134.98        | 0.00           | 0                | -66.23
-- 2026-05    | Activewear  | 3           | 6         | 168.24   | 215.00        | 28.21      | 26.97        | 160.74        | 14.97          | 0                | -277.65
-- 2026-05    | Outerwear   | 4           | 9         | 1259.91  | NULL          | 192.96     | 31.96        | 1252.41       | 14.97          | 2                | NULL
-- 2026-06    | Activewear  | 2           | 3         | 134.97   | NULL          | 22.23      | 11.98        | 132.47        | 4.99           | 2                | NULL
-- 2026-06    | Sleepwear   | 5           | 10        | 325.70   | NULL          | 53.80      | 40.95        | 315.70        | 19.96          | 2                | NULL
-- 2026-06    | Underwear   | 1           | 2         | 53.98    | 55.00         | 9.09       | 10.99        | 51.48         | 4.99           | 0                | -77.57
-- 2026-07    | Accessories | 3           | 6         | 139.44   | NULL          | 23.89      | 26.97        | 134.44        | 9.98           | 2                | NULL
-- 2026-07    | Activewear  | 1           | 1         | 53.99    | NULL          | 9.09       | 10.99        | 51.49         | 4.99           | 1                | NULL
-- 2026-07    | Bottoms     | 1           | 3         | 126.87   | 45.00         | 20.02      | 8.99         | 124.37        | 4.99           | 0                | -76.50
-- 2026-07    | Tops        | 2           | 3         | 89.07    | 35.00         | 15.34      | 11.98        | 84.07         | 9.98           | 0                | -67.30
-- 2026-07    | Underwear   | 1           | 3         | 67.47    | 90.00         | 11.11      | 4.99         | 67.47         | 0.00           | 0                | -106.10
-- 2026-08    | Activewear  | 1           | 1         | 44.99    | NULL          | 7.74       | 6.99         | 42.49         | 4.99           | 1                | NULL
-- 2026-08    | Bottoms     | 2           | 5         | 263.65   | NULL          | 41.53      | 15.98        | 258.65        | 9.98           | 1                | NULL
-- 2026-08    | Outerwear   | 1           | 2         | 251.98   | NULL          | 38.79      | 4.99         | 251.98        | 0.00           | 1                | NULL
-- 2026-08    | Tops        | 2           | 4         | 321.26   | 92.50         | 50.17      | 15.98        | 318.76        | 4.99           | 0                | -161.14
--
-- 19 rows selected.

-- ============================================================
-- Query 3: Complete return-reason breakdown
--
-- Business question:
-- How are all return reasons distributed within each product
-- category and brand, and how many involve size or fit?
--
-- Business Goal: 3
--
-- Features:
-- Multiple JOINs, GROUP BY, HAVING, COUNT, SUM,
-- LIKE, CASE, OVER, calculated percentages, ORDER BY.
--
-- All recorded return reasons are included.
-- Missing reasons are displayed as 'Unspecified'.
--
-- SizeFitReturnCount counts returns whose reason contains
-- 'size' or 'fit', ignoring letter case.
--
-- ReasonPct is the percentage of return records belonging
-- to each reason within the same category and brand.
-- It is NOT the percentage of sales returned.
--
-- ============================================================

PROMPT
PROMPT ===== QUERY 3: COMPLETE RETURN-REASON BREAKDOWN =====

COLUMN Category FORMAT A15
COLUMN Brand FORMAT A20
COLUMN ReturnReason FORMAT A25
COLUMN ReturnCount FORMAT 999990
COLUMN SizeFitReturnCount FORMAT 999990
COLUMN ReasonPct FORMAT 990.00
COLUMN TotalRefund FORMAT 999999990.00
COLUMN ReturnShipping FORMAT 9999990.00

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

-- Expected output (verified in Oracle Omega):
--
-- Category    | Brand               | ReturnReason     | ReturnCount | SizeFitReturnCount | ReasonPct | TotalRefund | ReturnShipping
-- Accessories | Carhartt            | Item Damaged     | 1           | 0                  | 100.00    | 41.38       | 0.00
-- Accessories | Dockers             | Not As Described | 1           | 0                  | 100.00    | 78.47       | 4.99
-- Accessories | Fruit of the Loom   | Wrong Size       | 1           | 1                  | 100.00    | 14.59       | 4.99
-- Activewear  | Adidas              | Defective Item   | 1           | 0                  | 100.00    | 62.99       | 0.00
-- Activewear  | CRZ Yoga            | Arrived Late     | 1           | 0                  | 100.00    | 75.77       | 4.99
-- Activewear  | Columbia            | Wrong Color      | 1           | 0                  | 100.00    | 42.49       | 4.99
-- Activewear  | Hanes               | Wrong Color      | 1           | 0                  | 100.00    | 24.49       | 4.99
-- Activewear  | Nike                | Arrived Late     | 1           | 0                  | 50.00     | 51.49       | 4.99
-- Activewear  | Nike                | Wrong Size       | 1           | 1                  | 50.00     | 69.48       | 4.99
-- Activewear  | Under Armour        | Poor Quality     | 1           | 0                  | 100.00    | 60.48       | 4.99
-- Bottoms     | Amazon Essentials   | Poor Quality     | 1           | 0                  | 100.00    | 124.37      | 4.99
-- Bottoms     | CRZ Yoga            | Defective Item   | 1           | 0                  | 100.00    | 97.17       | 0.00
-- Bottoms     | Calvin Klein        | Changed Mind     | 1           | 0                  | 100.00    | 172.97      | 4.99
-- Bottoms     | Dockers             | Arrived Late     | 1           | 0                  | 100.00    | 87.48       | 4.99
-- Bottoms     | Levi's              | Poor Quality     | 1           | 0                  | 100.00    | 51.49       | 4.99
-- Bottoms     | The Drop            | Item Damaged     | 1           | 0                  | 50.00     | 82.78       | 0.00
-- Bottoms     | The Drop            | Not As Described | 1           | 0                  | 50.00     | 85.68       | 4.99
-- Bottoms     | Wrangler            | Wrong Size       | 1           | 1                  | 100.00    | 27.19       | 4.99
-- Dresses     | ANRABESS            | Wrong Color      | 1           | 0                  | 100.00    | 96.48       | 4.99
-- Dresses     | Amazon Essentials   | Not As Described | 1           | 0                  | 100.00    | 113.57      | 4.99
-- Dresses     | Calvin Klein        | Changed Mind     | 1           | 0                  | 100.00    | 78.49       | 4.99
-- Dresses     | Ever-Pretty         | Poor Quality     | 1           | 0                  | 100.00    | 213.47      | 4.99
-- Dresses     | Levi's              | Arrived Late     | 1           | 0                  | 100.00    | 60.49       | 4.99
-- Outerwear   | Alpha Industries    | Defective Item   | 1           | 0                  | 100.00    | 251.98      | 0.00
-- Outerwear   | Calvin Klein        | Changed Mind     | 1           | 0                  | 100.00    | 510.47      | 4.99
-- Outerwear   | Columbia            | Defective Item   | 1           | 0                  | 50.00     | 134.98      | 0.00
-- Outerwear   | Columbia            | Not As Described | 1           | 0                  | 50.00     | 177.48      | 4.99
-- Outerwear   | Levi's              | Item Damaged     | 1           | 0                  | 100.00    | 80.99       | 0.00
-- Outerwear   | The North Face      | Wrong Size       | 1           | 1                  | 100.00    | 483.47      | 4.99
-- Sleepwear   | Amazon Essentials   | Item Damaged     | 1           | 0                  | 100.00    | 105.27      | 0.00
-- Sleepwear   | Ekouaer             | Not As Described | 1           | 0                  | 100.00    | 27.19       | 4.99
-- Sleepwear   | Fruit of the Loom   | Poor Quality     | 1           | 0                  | 100.00    | 37.99       | 4.99
-- Sleepwear   | Hanes               | Changed Mind     | 1           | 0                  | 100.00    | 47.88       | 4.99
-- Sleepwear   | Lands' End          | Wrong Color      | 1           | 0                  | 100.00    | 97.37       | 4.99
-- Tops        | Amazon Essentials   | Wrong Color      | 1           | 0                  | 50.00     | 43.37       | 4.99
-- Tops        | Amazon Essentials   | Wrong Size       | 1           | 1                  | 50.00     | 33.48       | 4.99
-- Tops        | Champion            | Wrong Color      | 1           | 0                  | 100.00    | 47.88       | 4.99
-- Tops        | Goodthreads         | Changed Mind     | 1           | 0                  | 50.00     | 36.19       | 4.99
-- Tops        | Goodthreads         | Item Damaged     | 1           | 0                  | 50.00     | 94.47       | 0.00
-- Tops        | Hanes               | Item Damaged     | 1           | 0                  | 50.00     | 24.29       | 0.00
-- Tops        | Hanes               | Not As Described | 1           | 0                  | 50.00     | 33.49       | 4.99
-- Tops        | Lands' End          | Wrong Size       | 1           | 1                  | 100.00    | 294.47      | 4.99
-- Tops        | Under Armour        | Changed Mind     | 1           | 0                  | 100.00    | 78.48       | 4.99
-- Underwear   | Calvin Klein        | Arrived Late     | 1           | 0                  | 100.00    | 51.48       | 4.99
-- Underwear   | Hanes               | Defective Item   | 1           | 0                  | 100.00    | 67.47       | 0.00
--
-- 45 rows selected.

-- ============================================================
-- Query 4: Monthly category sales with subtotals.
--
-- English:
-- Show net sales revenue and units sold for each month and
-- product category, followed by each month's subtotal and
-- an overall grand total.
--
-- Features: Multiple JOINs, ROLLUP, GROUPING, CASE, aggregates.
-- ============================================================

PROMPT
PROMPT ===== QUERY 4: MONTHLY CATEGORY SALES ROLLUP =====

COLUMN SalesMonth FORMAT A12
COLUMN CategoryLabel FORMAT A22
COLUMN UnitsSold FORMAT 9999990
COLUMN NetRevenue FORMAT 9999990.00

SELECT
    CASE
        WHEN GROUPING(TRUNC(ao.OrderDate, 'MM')) = 1
            THEN 'ALL MONTHS'
        ELSE TO_CHAR(TRUNC(ao.OrderDate, 'MM'), 'YYYY-MM')
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
        SUM(oi.Quantity * oi.SellingPricePerUnit - oi.Discount),
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

-- Expected output (verified in Oracle Omega, current database):
-- SalesMonth | CategoryLabel  | UnitsSold | NetRevenue
-- 2026-03    | Bottoms        | 6         | 241.14
-- 2026-03    | Tops           | 11        | 293.29
-- 2026-03    | MONTH TOTAL    | 17        | 534.43
-- 2026-04    | Bottoms        | 3         | 112.47
-- 2026-04    | Dresses        | 10        | 575.00
-- 2026-04    | Outerwear      | 2         | 134.98
-- 2026-04    | MONTH TOTAL    | 15        | 822.45
-- 2026-05    | Activewear     | 6         | 168.24
-- 2026-05    | Outerwear      | 9         | 1259.91
-- 2026-05    | MONTH TOTAL    | 15        | 1428.15
-- 2026-06    | Activewear     | 3         | 134.97
-- 2026-06    | Sleepwear      | 10        | 325.70
-- 2026-06    | Underwear      | 2         | 53.98
-- 2026-06    | MONTH TOTAL    | 15        | 514.65
-- 2026-07    | Accessories    | 6         | 139.44
-- 2026-07    | Activewear     | 1         | 53.99
-- 2026-07    | Bottoms        | 3         | 126.87
-- 2026-07    | Tops           | 3         | 89.07
-- 2026-07    | Underwear      | 3         | 67.47
-- 2026-07    | MONTH TOTAL    | 16        | 476.84
-- 2026-08    | Activewear     | 1         | 44.99
-- 2026-08    | Bottoms        | 5         | 263.65
-- 2026-08    | Outerwear      | 2         | 251.98
-- 2026-08    | Tops           | 4         | 321.26
-- 2026-08    | MONTH TOTAL    | 12         | 881.88
-- ALL MONTHS | GRAND TOTAL    | 90        | 4658.40
-- 26 rows selected.

-- ============================================================
-- Query 5: Supplier purchase-history coverage.
--
-- English:
-- Find suppliers for whom every product variant assigned to
-- that supplier has appeared in at least one received purchase
-- order issued to that same supplier.
-- Exclude suppliers with no assigned variants.
--
-- Features: Relational division, correlated nested subqueries,
--           NOT EXISTS, JOIN.
-- ============================================================

PROMPT
PROMPT ===== QUERY 5: SUPPLIERS COVERING ALL ASSIGNED VARIANTS =====

COLUMN SupplierName FORMAT A30
COLUMN Net30Status FORMAT A12
COLUMN CreditLimit FORMAT 9999990.00

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

-- Expected output (verified in Oracle Omega, current database):
-- SupplierID | SupplierName                   | Net30Status | CreditLimit
-- 17         | Atlantic Fashion Trading       | Active      | 45000.00
-- 36         | Brightline Textile Group       | Inactive    | 40000.00
-- 26         | Brookfield Clothing Partners   | Active      | 40000.00
-- 37         | Capital Garment Supply         | Active      | 45000.00
-- 7          | Coastal Denim Distributors     | Active      | 45000.00
-- 43         | Crown Apparel Wholesale        | Active      | 25000.00
-- 3          | Evergreen Fabric Distributors  | Active      | 25000.00
-- 33         | Frontier Clothing Wholesale    | Active      | 25000.00
-- 42         | Global Stitch Partners         | Active      | 20000.00
-- 2          | Golden State Apparel Supply    | Active      | 20000.00
-- 22         | Harbor Fashion Wholesale       | Active      | 20000.00
-- 38         | Horizon Fashion Wholesale      | Active      | 50000.00
-- 28         | Lakeside Garment Wholesale     | Inactive    | 50000.00
-- 11         | Liberty Textile Trading        | Active      | 15000.00
-- 27         | Meridian Textile Supply        | Active      | 45000.00
-- 13         | Oakwood Fashion Distributors   | Active      | 25000.00
-- 1          | Pacific Cotton Textiles        | Active      | 15000.00
-- 23         | Prime Stitch Textiles          | Active      | 25000.00
-- 41         | Riverside Textile Trading     | Active      | 15000.00
-- 32         | Royal Thread Supply            | Inactive    | 20000.00
-- 12         | Silverline Clothing Supply     | Inactive    | 20000.00
-- 31         | Skyline Apparel Trading       | Active      | 15000.00
-- 21         | Sterling Garment Distributors | Active      | 15000.00
-- 6          | Summit Fashion Supply          | Active      | 40000.00
-- 8          | Urban Thread Wholesale        | Inactive    | 50000.00
-- 16         | Valley Knitwear Supply        | Inactive    | 40000.00
-- 18         | Westbrook Apparel Group       | Active      | 50000.00
-- 27 rows selected.

-- ============================================================
-- Query 6: Top three revenue ranks of variants each month.
--
-- English:
-- Calculate each product variant's monthly units sold and
-- net revenue. Rank variants within each month by net revenue
-- and show the top three distinct revenue ranks, including ties.
-- Also show each variant's percentage of that month's revenue.
--
-- Features: Multiple JOINs, CTEs, GROUP BY, DENSE_RANK OVER,
--           SUM OVER, nested filtering.
-- ============================================================

PROMPT
PROMPT ===== QUERY 6: MONTHLY TOP VARIANTS =====

COLUMN SalesMonth FORMAT A10
COLUMN ProductName FORMAT A28
COLUMN Brand FORMAT A20
COLUMN NetRevenue FORMAT 9999990.00
COLUMN MonthlyRevenuePct FORMAT 990.00
COLUMN RevenueRank FORMAT 9990

SELECT
    TO_CHAR(rs.MonthStart, 'YYYY-MM') AS SalesMonth,
    rs.VariantID,
    rs.ProductName,
    rs.Brand,
    rs.UnitsSold,
    ROUND(rs.NetRevenue, 2) AS NetRevenue,
    rs.RevenueRank,
    rs.MonthlyRevenuePct
FROM (
    SELECT
        ms.MonthStart,
        ms.VariantID,
        ms.ProductName,
        ms.Brand,
        ms.UnitsSold,
        ms.NetRevenue,
        DENSE_RANK() OVER (
            PARTITION BY ms.MonthStart
            ORDER BY ms.NetRevenue DESC
        ) AS RevenueRank,
        ROUND(
            100 * ms.NetRevenue
            / NULLIF(
                SUM(ms.NetRevenue) OVER (
                    PARTITION BY ms.MonthStart
                ),
                0
            ),
            2
        ) AS MonthlyRevenuePct
    FROM (
        SELECT
            TRUNC(ao.OrderDate, 'MM') AS MonthStart,
            pv.VariantID,
            p.ProductName,
            p.Brand,
            SUM(oi.Quantity) AS UnitsSold,
            SUM(
                oi.Quantity * oi.SellingPricePerUnit
                - oi.Discount
            ) AS NetRevenue
        FROM F26_S001_T5_AMAZON_ORDER ao
        JOIN F26_S001_T5_ORDER_ITEM oi
            ON ao.OrderNumber = oi.OrderNumber
        JOIN F26_S001_T5_PRODUCT_VARIANT pv
            ON oi.VariantID = pv.VariantID
        JOIN F26_S001_T5_PRODUCT p
            ON pv.ProductID = p.ProductID
        GROUP BY
            TRUNC(ao.OrderDate, 'MM'),
            pv.VariantID,
            p.ProductName,
            p.Brand
    ) ms
) rs
WHERE rs.RevenueRank <= 3
ORDER BY rs.MonthStart, rs.RevenueRank, rs.VariantID;

-- Expected output (verified in Oracle Omega, current database):
-- SalesMonth | VariantID | ProductName                 | Brand             | UnitsSold | NetRevenue | RevenueRank | MonthlyRevenuePct
-- 2026-03    | 2008      | High Rise Leggings          | CRZ Yoga          | 3         | 97.17      | 1           | 18.18
-- 2026-03    | 2002      | Slim Fit Oxford Shirt       | Goodthreads       | 3         | 94.47      | 2           | 17.68
-- 2026-03    | 2007      | Slim Fit Chinos             | Dockers           | 2         | 89.98      | 3           | 16.84
-- 2026-04    | 2014      | Maxi Evening Dress          | Ever-Pretty       | 3         | 215.97     | 1           | 26.26
-- 2026-04    | 2016      | Lightweight Windbreaker     | Columbia          | 2         | 134.98     | 2           | 16.41
-- 2026-04    | 2011      | Floral Summer Dress         | Amazon Essentials | 3         | 116.07     | 3           | 14.11
-- 2026-05    | 2020      | Wool Blend Overcoat         | Calvin Klein      | 3         | 512.97     | 1           | 35.92
-- 2026-05    | 2017      | Puffer Winter Jacket        | The North Face    | 3         | 485.97     | 2           | 34.03
-- 2026-05    | 2019      | Waterproof Raincoat         | Columbia          | 2         | 179.98     | 3           | 12.60
-- 2026-06    | 2026      | Cotton Pajama Set           | Amazon Essentials | 3         | 105.27     | 1           | 20.45
-- 2026-06    | 2029      | Flannel Pajama Shirt        | Lands' End        | 3         | 99.87      | 2           | 19.41
-- 2026-06    | 2025      | Workout Training Tee        | Nike              | 2         | 71.98      | 3           | 13.99
-- 2026-07    | 2038      | Corduroy Trousers           | Amazon Essentials | 3         | 126.87     | 1           | 26.61
-- 2026-07    | 2035      | Leather Casual Belt         | Dockers           | 3         | 80.97      | 2           | 16.98
-- 2026-07    | 2032      | Seamless Briefs             | Hanes             | 3         | 67.47      | 3           | 14.15
-- 2026-08    | 2041      | Cashmere Blend Sweater      | Lands' End        | 3         | 296.97     | 1           | 33.67
-- 2026-08    | 2040      | Quilted Bomber Jacket       | Alpha Industries  | 2         | 251.98     | 2           | 28.57
-- 2026-08    | 2044      | Faux Leather Skirt         | Calvin Klein      | 3         | 175.47     | 3           | 19.90
-- 18 rows selected.

-- ============================================================
-- Query 7: Product price similarity recommendations.
--
-- Business question:
-- Which five product variants have pricing characteristics
-- most similar to the Classic Cotton T-Shirt (Variant 2001),
-- based on MSRP and selling price?
--
-- Features: Multiple JOINs, VECTOR_DISTANCE, TO_VECTOR,
--           ORDER BY, FETCH FIRST.
-- ============================================================

PROMPT
PROMPT ===== QUERY 7: PRODUCT PRICE SIMILARITY =====

COLUMN ProductName FORMAT A25
COLUMN Category FORMAT A20
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
                '[' || TO_CHAR(p.MSRP, 'FM999990D00', 'NLS_NUMERIC_CHARACTERS=''.,''')
                || ',' ||
                TO_CHAR(pv.SellingPrice, 'FM999990D00', 'NLS_NUMERIC_CHARACTERS=''.,''')
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

-- Expected output (verified in Oracle Omega):
-- VariantID  ProductName             Category      MSRP   SellingPrice  PriceDistance
-- 2033       Everyday Crew Socks     Accessories   18.99  17.09         1.35
-- 2005       Ribbed Tank Top         Tops          16.99  15.29         4.04
-- 2034       Winter Knit Beanie      Accessories   22.99  20.69         4.04
-- 2032       Seamless Briefs         Underwear     24.99  22.49         6.73
-- 2042       Cotton Henley Shirt     Tops          26.99  24.29         9.42
-- 5 rows selected.

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

COLUMN SupplierName FORMAT A30
COLUMN Net30Status FORMAT A11
COLUMN PaymentTerms FORMAT A12

COLUMN CreditLimit FORMAT 999999990.00
COLUMN RecordedSavingsPct FORMAT 990.00
COLUMN ScenarioSavingsPct FORMAT 990.00
COLUMN TotalOrderedValue FORMAT 999999990.00
COLUMN ReceivedPurchaseValue FORMAT 999999990.00
COLUMN AverageLeadDays FORMAT 9990.00
COLUMN OnTimePct FORMAT 990.00
COLUMN LineReturnRatePct FORMAT 990.00
COLUMN EstimatedEligibleSavings FORMAT 999999990.00
COLUMN PotentialAdditionalSavings FORMAT 999999990.00
COLUMN VerifiedActualSavings FORMAT 999999990.00
    
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

COLUMN ReportLevel FORMAT A18
COLUMN ShippingCarrier FORMAT A15
COLUMN ShippingService FORMAT A15
COLUMN DestinationRegion FORMAT A18
COLUMN WeightBand FORMAT A14

COLUMN Width FORMAT 9990.00
COLUMN Height FORMAT 9990.00
COLUMN AverageShippingCost FORMAT 999990.00
COLUMN AverageWeight FORMAT 9990.000
COLUMN AverageDeliveryDays FORMAT 9990.00
COLUMN OnTimePct FORMAT 990.00
    
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

COLUMN ReportLevel FORMAT A18
COLUMN Category FORMAT A15
COLUMN Brand FORMAT A20
COLUMN ProductName FORMAT A25
COLUMN VariantSize FORMAT A11
COLUMN Color FORMAT A10

COLUMN SoldLines FORMAT 9999990
COLUMN ReturnedLines FORMAT 9999990
COLUMN LineReturnRatePct FORMAT 990.00
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

COLUMN ReportMonth FORMAT A11

COLUMN NetSales FORMAT 999999990.00
COLUMN WholesaleCost FORMAT 999999990.00
COLUMN AmazonFees FORMAT 9999990.00
COLUMN ShippingCost FORMAT 9999990.00
COLUMN ReturnRefunds FORMAT 999999990.00
COLUMN ReturnShipping FORMAT 9999990.00
COLUMN OperatingCosts FORMAT 999999990.00
COLUMN EstimatedSalaries FORMAT 999999990.00
COLUMN EstimatedProfitLoss FORMAT 999999990.00
    
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

COLUMN ReportType FORMAT A8
COLUMN ProductName FORMAT A25
COLUMN ReportMonth FORMAT A11
COLUMN SeasonStart FORMAT A11
COLUMN DataStatus FORMAT A22

COLUMN ActualUnits FORMAT 9999990
COLUMN ForecastUnits FORMAT 9999990.00
COLUMN PriorYearsUsed FORMAT 9990
COLUMN ActualSeasonUnits FORMAT 9999990
COLUMN ForecastSeasonUnits FORMAT 9999990.00
    
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
COLUMN ReportLevel FORMAT A18
COLUMN Fname FORMAT A12
COLUMN Lname FORMAT A15

COLUMN AverageOrderValue FORMAT 9999990.00
COLUMN SingleVariantOrderPct FORMAT 990.00
COLUMN MultiVariantOrderPct FORMAT 990.00
COLUMN RepeatCustomerPct FORMAT 990.00

    
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
