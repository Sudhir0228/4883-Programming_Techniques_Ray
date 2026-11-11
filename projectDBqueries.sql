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
-- Query 8: Return cost analysis by category and brand
--
-- Business question:
-- Which ten category and brand groups have the highest
-- return-related costs? Show return counts, total refunds,
-- return-shipping costs, and restocking fees.
--
-- Business Goals:
-- Supports Goal 3's return analysis and the return-cost
-- components of Goals 1, 7, and 11.
-- This query does not calculate return rates or full profit.
--
-- Features:
-- Multiple JOINs, GROUP BY, COUNT, SUM,
-- calculated column, ORDER BY, FETCH FIRST.
--
-- Refund assumption:
-- RefundAmount is the actual amount refunded to the customer
-- AFTER deducting any restocking fee.
--
-- Example:
-- Original sale = 35.98
-- RestockingFee = 2.50
-- RefundAmount = 33.48
-- ReturnShippingCost = 4.99
-- NetReturnCost = 33.48 + 4.99 = 38.47
--
-- Net return cost = RefundAmount + ReturnShippingCost.
-- RestockingFee is displayed separately for reference.
-- It must NOT be subtracted again.
--
-- ReturnCount counts returned order lines, not returned units.
-- ============================================================

PROMPT
PROMPT ===== QUERY 8: RETURN COST ANALYSIS =====

COLUMN Category FORMAT A18
COLUMN Brand FORMAT A22
COLUMN ReturnCount FORMAT 999990
COLUMN TotalRefund FORMAT 9999990.00
COLUMN ReturnShipping FORMAT 9999990.00
COLUMN RestockingFees FORMAT 9999990.00
COLUMN NetReturnCost FORMAT 9999990.00

SELECT
    p.Category,
    p.Brand,
    COUNT(r.ReturnNumber) AS ReturnCount,
    ROUND(SUM(r.RefundAmount), 2) AS TotalRefund,
    ROUND(SUM(r.ReturnShippingCost), 2) AS ReturnShipping,
    ROUND(SUM(r.RestockingFee), 2) AS RestockingFees,
    ROUND(
        SUM(r.RefundAmount + r.ReturnShippingCost),
        2
    ) AS NetReturnCost
FROM F26_S001_T5_RETURN r
JOIN F26_S001_T5_ORDER_ITEM oi
    ON r.OrderNumber = oi.OrderNumber
   AND r.LineItemNumber = oi.LineItemNumber
JOIN F26_S001_T5_PRODUCT_VARIANT pv
    ON oi.VariantID = pv.VariantID
JOIN F26_S001_T5_PRODUCT p
    ON pv.ProductID = p.ProductID
GROUP BY
    p.Category,
    p.Brand
ORDER BY
    NetReturnCost DESC,
    p.Category,
    p.Brand
FETCH FIRST 10 ROWS ONLY;

-- Expected output (verified in Oracle Omega):
--
-- Category   | Brand            | ReturnCount | TotalRefund | ReturnShipping | RestockingFees | NetReturnCost
-- Outerwear  | Calvin Klein     | 1           | 510.47      | 4.99           | 2.50           | 515.46
-- Outerwear  | The North Face   | 1           | 483.47      | 4.99           | 2.50           | 488.46
-- Outerwear  | Columbia         | 2           | 312.46      | 4.99           | 2.50           | 317.45
-- Tops       | Lands' End       | 1           | 294.47      | 4.99           | 2.50           | 299.46
-- Outerwear  | Alpha Industries | 1           | 251.98      | 0.00           | 0.00           | 251.98
-- Dresses    | Ever-Pretty      | 1           | 213.47      | 4.99           | 2.50           | 218.46
-- Bottoms    | Calvin Klein     | 1           | 172.97      | 4.99           | 2.50           | 177.96
-- Bottoms    | The Drop         | 2           | 168.46      | 4.99           | 2.50           | 173.45
-- Tops       | Goodthreads      | 2           | 130.66      | 4.99           | 2.50           | 135.65
-- Activewear | Nike             | 2           | 120.97      | 9.98           | 5.00           | 130.95
--
-- 10 rows selected.

-- ============================================================
-- Query 9: Supplier performance summary
--
-- Business question:
-- How do suppliers compare on delivery reliability, actual
-- lead time, purchase history, customer-return rates,
-- Net 30 status, and credit limits?
--
-- Business Goal: 4
--
-- Features:
-- Multiple JOINs, aggregated subqueries, GROUP BY,
-- COUNT, SUM, AVG, CASE, calculated percentages, ORDER BY.
--
-- Column meanings:
-- ReceivedOrders: number of completed purchase orders.
-- OnTimePct: percentage of assessable Received orders
-- delivered by their estimated delivery date.
-- AvgLeadDays: average days from order placement to receipt.
-- PurchaseHistory: total ordered value across all statuses.
-- ReceivedValue: value of completed purchase orders.
-- ReturnRatePct: returned sales lines / sold sales lines * 100.
--
-- Pending and Shipped purchase orders remain valid records.
-- Their values are included in PurchaseHistory, but they
-- are excluded from completed-delivery measurements.
--
-- NULL delivery measures mean there are no assessable
-- completed observations for the corresponding calculation.
-- NULL return rate means there are no recorded sold lines.
--
-- Return rates measure returned order lines, not units.
-- Returns are attributed to each variant's current primary
-- supplier, not traced to individual purchase-order lots.
-- This association does not prove supplier fault.
--
-- Purchase and return data are aggregated separately
-- before joining to prevent multiplication of totals.
--
-- Sample-data limitation:
-- Each supplier currently has one purchase order and one
-- sold line with a return. This produces 100 percent return
-- rates and provides limited evidence for supplier comparison.
-- ============================================================

PROMPT
PROMPT ===== QUERY 9: SUPPLIER PERFORMANCE SUMMARY =====

COLUMN SupplierName FORMAT A30
COLUMN Net30Status FORMAT A11
COLUMN CreditLimit FORMAT 9999990.00
COLUMN ReceivedOrders FORMAT 999990
COLUMN OnTimePct FORMAT 990.00
COLUMN AvgLeadDays FORMAT 9990.00
COLUMN PurchaseHistory FORMAT 999999990.00
COLUMN ReceivedValue FORMAT 999999990.00
COLUMN ReturnRatePct FORMAT 990.00

SELECT
    s.SupplierID,
    s.SupplierName,
    s.Net30Status,
    s.CreditLimit,
    NVL(CompletedOrders, 0) AS ReceivedOrders,
    ROUND(
        100 * OnTimeOrders / NULLIF(AssessableOrders, 0),
        2
    ) AS OnTimePct,
    ROUND(ActualLeadDays, 2) AS AvgLeadDays,
    NVL(TotalOrderedValue, 0) AS PurchaseHistory,
    NVL(CompletedValue, 0) AS ReceivedValue,
    ROUND(
        100 * ReturnedLines / NULLIF(SoldLines, 0),
        2
    ) AS ReturnRatePct
FROM F26_S001_T5_SUPPLIER s
LEFT JOIN (
    SELECT
        po.SupplierID AS PurchaseSupplierID,
        SUM(
            CASE
                WHEN po.Status = 'Received' THEN 1
                ELSE 0
            END
        ) AS CompletedOrders,
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
        ) AS OnTimeOrders,
        AVG(
            CASE
                WHEN po.Status = 'Received'
                    THEN po.DateReceived - po.DatePlaced
            END
        ) AS ActualLeadDays,
        SUM(po.TotalCost) AS TotalOrderedValue,
        SUM(
            CASE
                WHEN po.Status = 'Received'
                    THEN po.TotalCost
                ELSE 0
            END
        ) AS CompletedValue
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
    AvgLeadDays ASC NULLS LAST,
    s.SupplierName;

-- Expected output (verified in Oracle Omega):
--
-- SupplierID | SupplierName                   | Net30Status | CreditLimit | ReceivedOrders | OnTimePct | AvgLeadDays | PurchaseHistory | ReceivedValue | ReturnRatePct
-- 36         | Brightline Textile Group       | Inactive    | 40000.00    | 1              | 100.00    | 8.00        | 400.00          | 400.00        | 100.00
-- 3          | Evergreen Fabric Distributors  | Active      | 25000.00    | 1              | 100.00    | 8.00        | 612.50          | 612.50        | 100.00
-- 33         | Frontier Clothing Wholesale    | Active      | 25000.00    | 1              | 100.00    | 8.00        | 812.50          | 812.50        | 100.00
-- 42         | Global Stitch Partners         | Active      | 20000.00    | 1              | 100.00    | 8.00        | 750.00          | 750.00        | 100.00
-- 27         | Meridian Textile Supply        | Active      | 45000.00    | 1              | 100.00    | 8.00        | 612.50          | 612.50        | 100.00
-- 12         | Silverline Clothing Supply     | Inactive    | 20000.00    | 1              | 100.00    | 8.00        | 400.00          | 400.00        | 100.00
-- 21         | Sterling Garment Distributors  | Active      | 15000.00    | 1              | 100.00    | 8.00        | 1462.50         | 1462.50       | 100.00
-- 6          | Summit Fashion Supply          | Active      | 40000.00    | 1              | 100.00    | 8.00        | 1250.00         | 1250.00       | 100.00
-- 18         | Westbrook Apparel Group        | Active      | 50000.00    | 1              | 100.00    | 8.00        | 750.00          | 750.00        | 100.00
-- 37         | Capital Garment Supply         | Active      | 45000.00    | 1              | 100.00    | 9.00        | 562.50          | 562.50        | 100.00
-- 7          | Coastal Denim Distributors     | Active      | 45000.00    | 1              | 100.00    | 9.00        | 1512.50         | 1512.50       | 100.00
-- 43         | Crown Apparel Wholesale        | Active      | 25000.00    | 1              | 100.00    | 9.00        | 962.50          | 962.50        | 100.00
-- 22         | Harbor Fashion Wholesale       | Active      | 20000.00    | 1              | 100.00    | 9.00        | 1750.00         | 1750.00       | 100.00
-- 28         | Lakeside Garment Wholesale      | Inactive    | 50000.00    | 1              | 100.00    | 9.00        | 800.00          | 800.00        | 100.00
-- 13         | Oakwood Fashion Distributors   | Active      | 25000.00    | 1              | 100.00    | 9.00        | 562.50          | 562.50        | 100.00
-- 1          | Pacific Cotton Textiles        | Active      | 15000.00    | 1              | 100.00    | 9.00        | 312.50          | 312.50        | 100.00
-- 31         | Skyline Apparel Trading        | Active      | 15000.00    | 1              | 100.00    | 9.00        | 1512.50         | 1512.50       | 100.00
-- 16         | Valley Knitwear Supply         | Inactive    | 40000.00    | 1              | 100.00    | 9.00        | 400.00          | 400.00        | 100.00
-- 17         | Atlantic Fashion Trading       | Active      | 45000.00    | 1              | 100.00    | 10.00       | 562.50          | 562.50        | 100.00
-- 26         | Brookfield Clothing Partners   | Active      | 40000.00    | 1              | 100.00    | 10.00       | 450.00          | 450.00        | 100.00
-- 2          | Golden State Apparel Supply    | Active      | 20000.00    | 1              | 100.00    | 10.00       | 450.00          | 450.00        | 100.00
-- 38         | Horizon Fashion Wholesale      | Active      | 50000.00    | 1              | 100.00    | 10.00       | 750.00          | 750.00        | 100.00
-- 11         | Liberty Textile Trading        | Active      | 15000.00    | 1              | 100.00    | 10.00       | 1312.50         | 1312.50       | 100.00
-- 23         | Prime Stitch Textiles          | Active      | 25000.00    | 1              | 100.00    | 10.00       | 2062.50         | 2062.50       | 100.00
-- 41         | Riverside Textile Trading      | Active      | 15000.00    | 1              | 100.00    | 10.00       | 562.50          | 562.50        | 100.00
-- 32         | Royal Thread Supply            | Inactive    | 20000.00    | 1              | 100.00    | 10.00       | 600.00          | 600.00        | 100.00
-- 8          | Urban Thread Wholesale         | Inactive    | 50000.00    | 1              | 100.00    | 10.00       | 600.00          | 600.00        | 100.00
-- 29         | Aspire Fashion Distributors    | Active      | 55000.00    | 0              | NULL      | NULL        | 1012.50         | 0.00          | 100.00
-- 5          | Blue Ridge Textile Group       | Active      | 35000.00    | 0              | NULL      | NULL        | 1012.50         | 0.00          | 100.00
-- 24         | Canyon Apparel Supply          | Inactive    | 30000.00    | 0              | NULL      | NULL        | 200.00          | 0.00          | 100.00
-- 30         | Cedar Valley Textiles          | Active      | 10000.00    | 0              | NULL      | NULL        | 1250.00         | 0.00          | 100.00
-- 45         | Continental Fashion Textiles   | Active      | 35000.00    | 0              | NULL      | NULL        | 1462.50         | 0.00          | 100.00
-- 19         | Crescent Textile Partners      | Active      | 55000.00    | 0              | NULL      | NULL        | 962.50          | 0.00          | 100.00
-- 34         | Diamond Fabric Partners        | Active      | 30000.00    | 0              | NULL      | NULL        | 1050.00         | 0.00          | 100.00
-- 40         | Elite Cotton Distributors      | Inactive    | 10000.00    | 0              | NULL      | NULL        | 400.00          | 0.00          | 100.00
-- 25         | Grandview Fabric Company       | Active      | 35000.00    | 0              | NULL      | NULL        | 312.50          | 0.00          | 100.00
-- 9          | Heritage Garment Supply        | Active      | 55000.00    | 0              | NULL      | NULL        | 812.50          | 0.00          | 100.00
-- 35         | Maple Grove Apparel            | Active      | 35000.00    | 0              | NULL      | NULL        | 1312.50         | 0.00          | 100.00
-- 14         | Metro Garment Wholesale        | Active      | 30000.00    | 0              | NULL      | NULL        | 750.00          | 0.00          | 100.00
-- 4          | Northstar Clothing Wholesale   | Inactive    | 30000.00    | 0              | NULL      | NULL        | 800.00          | 0.00          | 100.00
-- 15         | Pioneer Cotton Company         | Active      | 35000.00    | 0              | NULL      | NULL        | 962.50          | 0.00          | 100.00
-- 44         | Premier Garment Supply         | Inactive    | 30000.00    | 0              | NULL      | NULL        | 1200.00         | 0.00          | 100.00
-- 20         | Redwood Clothing Supply        | Inactive    | 10000.00    | 0              | NULL      | NULL        | 1200.00         | 0.00          | 100.00
-- 39         | Stonebridge Clothing Supply    | Active      | 55000.00    | 0              | NULL      | NULL        | 962.50          | 0.00          | 100.00
-- 10         | Sunrise Apparel Partners       | Active      | 10000.00    | 0              | NULL      | NULL        | 1050.00         | 0.00          | 100.00
--
-- 45 rows selected.

-- ============================================================
-- Query 10: Shipping carrier and service performance analysis.
--
-- English:
--
-- Compare shipping carriers and shipping services by
-- calculating the number of orders shipped, customers served,
-- average shipping cost, average package weight, average
-- delivery time, on-time deliveries, late deliveries, and
-- on-time delivery percentage.
--
-- Business Goal: 12
--
-- Features: JOIN, GROUP BY, aggregate functions, CASE,
--           calculated percentage, ORDER BY.
-- ============================================================

PROMPT
PROMPT ===== QUERY 10: SHIPPING PERFORMANCE ANALYSIS =====

COLUMN ShippingCarrier FORMAT A16
COLUMN ShippingService FORMAT A14
COLUMN TotalOrders FORMAT 999
COLUMN CustomersServed FORMAT 999
COLUMN AverageShippingCost FORMAT 990.00
COLUMN AverageWeight FORMAT 990.00
COLUMN AverageDeliveryDays FORMAT 990.00
COLUMN OnTimeOrders FORMAT 999
COLUMN LateOrders FORMAT 999
COLUMN OnTimePercentage FORMAT 990.00

SELECT
    ao.ShippingCarrier,
    ao.ShippingService,
    COUNT(ao.OrderNumber) AS TotalOrders,
    COUNT(DISTINCT ao.CustomerID) AS CustomersServed,
    ROUND(AVG(ao.ShippingCost), 2) AS AverageShippingCost,
    ROUND(AVG(ao.PackageWeight), 2) AS AverageWeight,
    ROUND(
        AVG(ao.ActualDeliveryDate - ao.ShippingDate),
        2
    ) AS AverageDeliveryDays,
    SUM(
        CASE
            WHEN ao.ActualDeliveryDate <= ao.ExpectedDate
            THEN 1
            ELSE 0
        END
    ) AS OnTimeOrders,
    SUM(
        CASE
            WHEN ao.ActualDeliveryDate > ao.ExpectedDate
            THEN 1
            ELSE 0
        END
    ) AS LateOrders,
    ROUND(
        100 * SUM(
            CASE
                WHEN ao.ActualDeliveryDate <= ao.ExpectedDate
                THEN 1
                ELSE 0
            END
        ) / COUNT(ao.OrderNumber),
        2
    ) AS OnTimePercentage
FROM F26_S001_T5_AMAZON_ORDER ao
JOIN F26_S001_T5_CUSTOMER c
    ON ao.CustomerID = c.CustomerID
WHERE ao.ActualDeliveryDate IS NOT NULL
  AND ao.ExpectedDate IS NOT NULL
GROUP BY
    ao.ShippingCarrier,
    ao.ShippingService
ORDER BY
    OnTimePercentage DESC,
    AverageShippingCost ASC,
    ao.ShippingCarrier;

-- Expected output (initial populated database, before updates; verified in Oracle Omega):
-- ShippingCarrier | ShippingService | TotalOrders | CustomersServed | AvgShippingCost | AvgWeight | AvgDeliveryDays | OnTime | Late | OnTime%
-- FedEx           | Standard        | 15          | 15              | 7.79            | 1.32      | 4.00            | 15     | 0    | 100.00
-- UPS             | Ground          | 15          | 15              | 7.92            | 1.33      | 4.00            | 15     | 0    | 100.00
-- USPS            | Express         | 15          | 15              | 8.19            | 1.43      | 4.00            | 15     | 0    | 100.00
-- 3 rows selected.

-- ============================================================
-- Query 11: Product-variant profitability
--
-- Business question:
-- What estimated contribution does each sold product variant
-- generate after wholesale costs, Amazon fees, outbound
-- shipping, actual refunds, and return-shipping costs?
--
-- Business Goal: 7
--
-- Features:
-- Multiple JOINs, subqueries, GROUP BY,
-- SUM, COUNT, CASE, OVER, calculated columns, ORDER BY.
--
-- Missing-cost limitation:
-- Some sold variants lack Received purchase-cost records.
-- This may represent opening inventory whose acquisition
-- costs were not imported.
-- A pending replenishment order does not cause missing cost
-- if an earlier Received purchase provides a known cost.
--
-- Unknown costs are not treated as zero.
-- MissingCostLines counts sales lines missing any required
-- wholesale cost, Amazon fee, or outbound shipping cost.
-- Contribution is NULL if any required cost is missing.
--
-- Sample-data limitation:
-- Every sold line currently has a return record.
-- Negative contribution is therefore expected for variants
-- with complete costs under the stated calculation.
--
-- All sold variants are included, not only the top ten.
-- ============================================================

PROMPT
PROMPT ===== QUERY 11: PRODUCT-VARIANT PROFITABILITY =====

COLUMN ProductName FORMAT A30
COLUMN VariantSize FORMAT A11
COLUMN Color FORMAT A10
COLUMN UnitsSold FORMAT 999990
COLUMN NetSales FORMAT 999999990.00
COLUMN WholesaleCost FORMAT 999999990.00
COLUMN AmazonFees FORMAT 9999990.00
COLUMN ShippingCost FORMAT 9999990.00
COLUMN ReturnCost FORMAT 9999990.00
COLUMN MissingCostLines FORMAT 999990
COLUMN EstimatedNetContribution FORMAT 999999990.00

SELECT
    VariantID,
    ProductName,
    VariantSize,
    Color,
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
    ROUND(SUM(LineReturnCost), 2) AS ReturnCost,
    SUM(MissingCostLine) AS MissingCostLines,
    CASE
        WHEN SUM(MissingCostLine) = 0
            THEN ROUND(
                SUM(
                    NetSales
                    - LineWholesaleCost
                    - LineAmazonFees
                    - LineShippingCost
                    - LineReturnCost
                ),
                2
            )
    END AS EstimatedNetContribution
FROM (
    SELECT
        VariantID,
        ProductName,
        VariantSize,
        Color,
        Quantity,
        NetSales,
        LineWholesaleCost,
        AllocationShare * OrderAmazonFees AS LineAmazonFees,
        AllocationShare * OrderShippingCost AS LineShippingCost,
        LineReturnCost,
        MissingCostLine
    FROM (
        SELECT
            pv.VariantID,
            p.ProductName,
            pv.VariantSize,
            pv.Color,
            oi.Quantity,
            oi.Quantity * oi.SellingPricePerUnit
                - oi.Discount AS NetSales,
            oi.Quantity * AverageUnitCost AS LineWholesaleCost,
            ao.AmazonReferralCost + ao.SubscriptionCost
                AS OrderAmazonFees,
            ao.ShippingCost AS OrderShippingCost,
            NVL(r.RefundAmount, 0)
                + NVL(r.ReturnShippingCost, 0) AS LineReturnCost,
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
GROUP BY
    VariantID,
    ProductName,
    VariantSize,
    Color
ORDER BY
    EstimatedNetContribution DESC NULLS LAST,
    VariantID;

-- Expected output (verified in Oracle Omega):
--
-- VariantID | ProductName                  | VariantSize | Color | UnitsSold | NetSales | WholesaleCost | AmazonFees | ShippingCost | ReturnCost | MissingCostLines | EstimatedNetContribution
-- 2036      | Linen Button-Up Shirt        | XXL         | Red   | 1         | 38.69    | 10.00         | 6.79       | 4.99         | 41.18      | 0                | -24.27
-- 2012      | Formal Wrap Dress            | S           | White | 1         | 80.99    | 10.00         | 13.14      | 4.99         | 83.48      | 0                | -30.62
-- 2027      | Satin Nightgown              | One Size    | Green | 1         | 29.69    | 17.50         | 5.44       | 10.99        | 32.18      | 0                | -36.42
-- 2003      | Relaxed Fit Hoodie           | M           | Navy  | 1         | 35.99    | 17.50         | 6.39       | 10.99        | 38.48      | 0                | -37.37
-- 2042      | Cotton Henley Shirt          | S           | White | 1         | 24.29    | 25.00         | 4.63       | 8.99         | 24.29      | 0                | -38.62
-- 2001      | Classic Cotton T-Shirt       | XS          | Black | 2         | 35.98    | 25.00         | 6.39       | 6.99         | 38.47      | 0                | -40.87
-- 2037      | Oversized Graphic Tee        | One Size    | Green | 2         | 50.38    | 25.00         | 8.55       | 6.99         | 52.87      | 0                | -43.03
-- 2033      | Everyday Crew Socks          | M           | Navy  | 1         | 17.09    | 32.50         | 3.55       | 6.99         | 19.58      | 0                | -45.53
-- 2006      | Straight Leg Jeans           | XXL         | Red   | 1         | 53.99    | 25.00         | 9.09       | 8.99         | 56.48      | 0                | -45.57
-- 2021      | Fleece Jogger Pants          | XS          | Black | 1         | 26.99    | 32.50         | 5.04       | 6.99         | 29.48      | 0                | -47.02
-- 2018      | Classic Denim Jacket         | 30          | Beige | 1         | 80.99    | 25.00         | 13.14      | 8.99         | 80.99      | 0                | -47.13
-- 2013      | Knit Sweater Dress           | M           | Navy  | 2         | 98.98    | 25.00         | 15.84      | 6.99         | 101.47     | 0                | -50.32
-- 2028      | Fleece Lounge Pants          | 30          | Beige | 2         | 50.38    | 40.00         | 8.55       | 4.99         | 52.87      | 0                | -56.03
-- 2016      | Lightweight Windbreaker      | XXL         | Red   | 2         | 134.98   | 40.00         | 21.24      | 4.99         | 134.98     | 0                | -66.23
-- 2002      | Slim Fit Oxford Shirt        | S           | White | 3         | 94.47    | 45.00         | 15.16      | 8.99         | 94.47      | 0                | -69.15
-- 2026      | Cotton Pajama Set            | XXL         | Red   | 3         | 105.27   | 45.00         | 16.78      | 8.99         | 105.27     | 0                | -70.77
-- 2038      | Corduroy Trousers            | 30          | Beige | 3         | 126.87   | 45.00         | 20.02      | 8.99         | 129.36     | 0                | -76.50
-- 2031      | Cotton Boxer Briefs          | XS          | Black | 2         | 53.98    | 55.00         | 9.09       | 10.99        | 56.47      | 0                | -77.57
-- 2043      | Wide Leg Palazzo Pants       | M           | Navy  | 2         | 88.18    | 55.00         | 14.22      | 10.99        | 90.67      | 0                | -82.70
-- 2007      | Slim Fit Chinos              | One Size    | Green | 2         | 89.98    | 55.00         | 14.49      | 10.99        | 92.47      | 0                | -82.97
-- 2022      | Running Compression Shorts   | S           | White | 2         | 62.98    | 70.00         | 10.44      | 8.99         | 65.47      | 0                | -91.92
-- 2032      | Seamless Briefs              | S           | White | 3         | 67.47    | 90.00         | 11.11      | 4.99         | 67.47      | 0                | -106.10
-- 2008      | High Rise Leggings           | 30          | Beige | 3         | 97.17    | 90.00         | 15.57      | 4.99         | 97.17      | 0                | -110.56
-- 2041      | Cashmere Blend Sweater       | XS          | Black | 3         | 296.97   | 67.50         | 45.54      | 6.99         | 299.46     | 0                | -122.52
-- 2023      | Yoga Sports Bra              | M           | Navy  | 3         | 78.27    | 112.50        | 12.73      | 10.99        | 80.76      | 0                | -138.71
-- 2011      | Floral Summer Dress          | XS          | Black | 3         | 116.07   | 112.50        | 18.40      | 10.99        | 118.56     | 0                | -144.38
-- 2017      | Puffer Winter Jacket         | One Size    | Green | 3         | 485.97   | 67.50         | 73.89      | 6.99         | 488.46     | 0                | -150.87
-- 2004      | Performance Polo Shirt       | L           | Gray  | 2         | 80.98    | NULL          | 13.14      | 4.99         | 83.47      | 1                | NULL
-- 2005      | Ribbed Tank Top              | XL          | Blue  | 3         | 45.87    | NULL          | 7.87       | 6.99         | 48.36      | 1                | NULL
-- 2009      | Cargo Shorts                 | 32          | Brown | 1         | 29.69    | NULL          | 5.44       | 6.99         | 32.18      | 1                | NULL
-- 2010      | Pleated Midi Skirt           | 34          | Pink  | 2         | 82.78    | NULL          | 13.41      | 8.99         | 82.78      | 1                | NULL
-- 2014      | Maxi Evening Dress           | L           | Gray  | 3         | 215.97   | NULL          | 33.39      | 8.99         | 218.46     | 1                | NULL
-- 2015      | Denim Shirt Dress            | XL          | Blue  | 1         | 62.99    | NULL          | 10.44      | 10.99        | 65.48      | 1                | NULL
-- 2019      | Waterproof Raincoat          | 32          | Brown | 2         | 179.98   | NULL          | 27.99      | 10.99        | 182.47     | 1                | NULL
-- 2020      | Wool Blend Overcoat          | 34          | Pink  | 3         | 512.97   | NULL          | 77.94      | 4.99         | 515.46     | 1                | NULL
-- 2024      | Training Track Jacket        | L           | Gray  | 1         | 62.99    | NULL          | 10.44      | 4.99         | 62.99      | 1                | NULL
-- 2025      | Workout Training Tee         | XL          | Blue  | 2         | 71.98    | NULL          | 11.79      | 6.99         | 74.47      | 1                | NULL
-- 2029      | Flannel Pajama Shirt         | 32          | Brown | 3         | 99.87    | NULL          | 15.97      | 6.99         | 102.36     | 1                | NULL
-- 2030      | Thermal Sleep Set            | 34          | Pink  | 1         | 40.49    | NULL          | 7.06       | 8.99         | 42.98      | 1                | NULL
-- 2034      | Winter Knit Beanie           | L           | Gray  | 2         | 41.38    | NULL          | 7.20       | 8.99         | 41.38      | 1                | NULL
-- 2035      | Leather Casual Belt          | XL          | Blue  | 3         | 80.97    | NULL          | 13.14      | 10.99        | 83.46      | 1                | NULL
-- 2039      | Athletic Running Leggings    | 32          | Brown | 1         | 53.99    | NULL          | 9.09       | 10.99        | 56.48      | 1                | NULL
-- 2040      | Quilted Bomber Jacket        | 34          | Pink  | 2         | 251.98   | NULL          | 38.79      | 4.99         | 251.98     | 1                | NULL
-- 2044      | Faux Leather Skirt           | L           | Gray  | 3         | 175.47   | NULL          | 27.31      | 4.99         | 177.96     | 1                | NULL
-- 2045      | Thermal Base Layer Top       | XL          | Blue  | 1         | 44.99    | NULL          | 7.74       | 6.99         | 47.48      | 1                | NULL
--
-- 45 rows selected.

-- ============================================================
-- Query 12: Monthly profit and loss estimate
--
-- Business question:
-- What are monthly sales, wholesale costs, Amazon fees,
-- outbound shipping, refunds, return shipping, operating
-- expenses, estimated salaries, and profit or loss?
--
-- Business Goal: 9
--
-- Features:
-- Multiple JOINs, subqueries, GROUP BY, SUM,
-- CASE, calendar generation, calculated columns, ORDER BY.
-- ============================================================

PROMPT
PROMPT ===== QUERY 12: MONTHLY PROFIT AND LOSS =====

COLUMN ReportMonth FORMAT A11
COLUMN NetSales FORMAT 999999990.00
COLUMN WholesaleCost FORMAT 999999990.00
COLUMN AmazonFees FORMAT 9999990.00
COLUMN ShippingCost FORMAT 9999990.00
COLUMN ReturnRefunds FORMAT 999999990.00
COLUMN ReturnShipping FORMAT 9999990.00
COLUMN OperatingCosts FORMAT 999999990.00
COLUMN EstimatedSalaries FORMAT 999999990.00
COLUMN MissingCostLines FORMAT 999990
COLUMN MissingCostOrders FORMAT 999990
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
                NetSales
                - WholesaleCost
                - AmazonFees
                - ShippingCost
                - ReturnRefunds
                - ReturnShipping
                - OperatingCosts
                - EstimatedSalaries,
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

-- Expected output (verified in Oracle Omega, updated database):
--
-- ReportMonth | NetSales | WholesaleCost | AmazonFees | ShippingCost | ReturnRefunds | ReturnShipping | OperatingCosts | EstimatedSalaries | MissingCostLines | MissingCostOrders | EstimatedProfitLoss
-- 2026-01     | 0.00     | 0.00          | 0.00       | 0.00         | 0.00          | 0.00           | 5369.00        | 228166.67         | 0                | 0                 | -233535.67
-- 2026-02     | 0.00     | 0.00          | 0.00       | 0.00         | 0.00          | 0.00           | 1645.00        | 228166.67         | 0                | 0                 | -229811.67
-- 2026-03     | 534.43   | NULL          | 88.10      | 63.92        | 283.29        | 19.96          | 9670.00        | 228166.67         | 2                | 0                 | NULL
-- 2026-04     | 822.45   | NULL          | 131.30     | 63.92        | 634.65        | 29.94          | 5369.00        | 228166.67         | 4                | 0                 | NULL
-- 2026-05     | 1428.15  | NULL          | 221.17     | 58.93        | 1661.35       | 24.95          | 1645.00        | 228166.67         | 2                | 0                 | NULL
-- 2026-06     | 514.65   | NULL          | 85.12      | 63.92        | 473.55        | 29.94          | 9670.00        | 228166.67         | 4                | 0                 | NULL
-- 2026-07     | 476.84   | NULL          | 79.45      | 63.92        | 424.94        | 29.94          | 5369.00        | 228166.67         | 3                | 0                 | NULL
-- 2026-08     | 881.88   | NULL          | 138.23     | 43.94        | 880.16        | 24.95          | 1645.00        | 228166.67         | 3                | 0                 | NULL
-- 2026-09     | 0.00     | 0.00          | 0.00       | 0.00         | 215.46        | 9.98           | 9460.00        | 228166.67         | 0                | 0                 | -237852.11
-- 2026-10     | 0.00     | 0.00          | 0.00       | 0.00         | 0.00          | 0.00           | 0.00           | 228166.67         | 0                | 0                 | -228166.67
-- 2026-11     | 0.00     | 0.00          | 0.00       | 0.00         | 0.00          | 0.00           | 125.00         | 228166.67         | 0                | 0                 | -228291.67
--
-- 11 rows selected.

-- ============================================================
-- Query 13: Customer purchase behavior
--
-- Business question:
-- What are average order value, single-versus-multiple-variant
-- purchasing patterns, and repeat purchase rates for each
-- purchasing customer and for the business overall?
--
-- Business Goal: 10
--
-- Features:
-- Multiple JOINs, subqueries, GROUP BY, GROUPING SETS,
-- GROUPING, CASE, SUM, COUNT, calculated percentages,
-- ORDER BY.
--
-- Sample-data limitation:
-- The current sample has one order per purchasing customer
-- and one distinct variant per order. Zero repeat customers
-- and zero multiple-variant orders are therefore expected.
-- These figures describe recorded data, not unrecorded history.
-- ============================================================

PROMPT
PROMPT ===== QUERY 13: CUSTOMER PURCHASE BEHAVIOR =====

COLUMN ReportLevel FORMAT A12
COLUMN Fname FORMAT A12
COLUMN Lname FORMAT A15
COLUMN PurchasingCustomers FORMAT 999990
COLUMN TotalOrders FORMAT 999990
COLUMN AverageOrderValue FORMAT 9999990.00
COLUMN SingleVariantOrders FORMAT 999990
COLUMN MultiVariantOrders FORMAT 999990
COLUMN SingleVariantOrderPct FORMAT 990.00
COLUMN MultiVariantOrderPct FORMAT 990.00
COLUMN RepeatCustomers FORMAT 999990
COLUMN RepeatCustomerPct FORMAT 990.00

SELECT
    CASE
        WHEN GROUPING(CustomerID) = 1
            THEN 'ALL BUYERS'
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
        GROUP BY
            ao.OrderNumber,
            ao.CustomerID
    )
        ON OrderCustomerID = c.CustomerID
    GROUP BY
        c.CustomerID,
        c.Fname,
        c.Lname
)
GROUP BY GROUPING SETS (
    (CustomerID, Fname, Lname),
    ()
)
ORDER BY
    ReportLevel,
    CustomerID;

-- Expected output (verified in Oracle Omega):
--
-- ReportLevel | CustomerID | Fname     | Lname     | PurchasingCustomers | TotalOrders | AverageOrderValue | SingleVariantOrders | MultiVariantOrders | SingleVariantOrderPct | MultiVariantOrderPct | RepeatCustomers | RepeatCustomerPct
-- ALL BUYERS  | NULL       | NULL      | NULL      | 45                  | 45          | 103.52            | 45                  | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5001       | James     | Miller    | 1                   | 1           | 35.98             | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5002       | Emma      | Wilson    | 1                   | 1           | 94.47             | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5003       | Michael   | Garcia    | 1                   | 1           | 35.99             | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5004       | Olivia    | Gonzalez  | 1                   | 1           | 80.98             | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5005       | William   | Jones     | 1                   | 1           | 45.87             | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5006       | Sophia    | Lopez     | 1                   | 1           | 53.99             | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5007       | Daniel    | Brown     | 1                   | 1           | 89.98             | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5008       | Ava       | Hernandez | 1                   | 1           | 97.17             | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5009       | Benjamin  | Williams  | 1                   | 1           | 29.69             | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5010       | Isabella  | Martinez  | 1                   | 1           | 82.78             | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5011       | Alexander | Johnson   | 1                   | 1           | 116.07            | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5012       | Mia       | Rodriguez | 1                   | 1           | 80.99             | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5013       | Ethan     | Smith     | 1                   | 1           | 98.98             | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5014       | Charlotte | Davis     | 1                   | 1           | 215.97            | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5015       | Lucas     | Anderson  | 1                   | 1           | 62.99             | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5016       | James     | Miller    | 1                   | 1           | 134.98            | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5017       | Emma      | Wilson    | 1                   | 1           | 485.97            | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5018       | Michael   | Garcia    | 1                   | 1           | 80.99             | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5019       | Olivia    | Gonzalez  | 1                   | 1           | 179.98            | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5020       | William   | Jones     | 1                   | 1           | 512.97            | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5021       | Sophia    | Lopez     | 1                   | 1           | 26.99             | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5022       | Daniel    | Brown     | 1                   | 1           | 62.98             | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5023       | Ava       | Hernandez | 1                   | 1           | 78.27             | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5024       | Benjamin  | Williams  | 1                   | 1           | 62.99             | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5025       | Isabella  | Martinez  | 1                   | 1           | 71.98             | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5026       | Alexander | Johnson   | 1                   | 1           | 105.27            | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5027       | Mia       | Rodriguez | 1                   | 1           | 29.69             | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5028       | Ethan     | Smith     | 1                   | 1           | 50.38             | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5029       | Charlotte | Davis     | 1                   | 1           | 99.87             | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5030       | Lucas     | Anderson  | 1                   | 1           | 40.49             | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5031       | James     | Miller    | 1                   | 1           | 53.98             | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5032       | Emma      | Wilson    | 1                   | 1           | 67.47             | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5033       | Michael   | Garcia    | 1                   | 1           | 17.09             | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5034       | Olivia    | Gonzalez  | 1                   | 1           | 41.38             | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5035       | William   | Jones     | 1                   | 1           | 80.97             | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5036       | Sophia    | Lopez     | 1                   | 1           | 38.69             | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5037       | Daniel    | Brown     | 1                   | 1           | 50.38             | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5038       | Ava       | Hernandez | 1                   | 1           | 126.87            | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5039       | Benjamin  | Williams  | 1                   | 1           | 53.99             | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5040       | Isabella  | Martinez  | 1                   | 1           | 251.98            | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5041       | Alexander | Johnson   | 1                   | 1           | 296.97            | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5042       | Mia       | Rodriguez | 1                   | 1           | 24.29             | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5043       | Ethan     | Smith     | 1                   | 1           | 88.18             | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5044       | Charlotte | Davis     | 1                   | 1           | 175.47            | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
-- CUSTOMER    | 5045       | Lucas     | Anderson  | 1                   | 1           | 44.99             | 1                   | 0                  | 100.00                | 0.00                 | 0               | 0.00
--
-- 46 rows selected.

-- ============================================================
-- Query 14: Brand performance
--
-- Business question:
-- Which brands perform best in sales revenue, estimated
-- contribution margin, and observed return rate?
--
-- Business Goal: 11
--
-- Features:
-- Multiple JOINs, subqueries, GROUP BY,
-- SUM, COUNT, CASE, OVER, calculated columns, ORDER BY.
--
-- Missing-cost limitation:
-- Some sold variants lack Received purchase-cost records.
-- This may represent opening inventory whose acquisition
-- costs were not imported.
-- Unknown costs are not treated as zero.
-- If any required cost is missing, the brand's estimated
-- contribution and margin are shown as NULL.
-- MissingCostLines identifies the number of affected lines.
--
-- Sample-data limitation:
-- Every recorded sold line currently has a return.
-- Return rates of 100 percent and negative contributions
-- are therefore expected under these assumptions.
-- ReturnCost may exceed NetSales because it includes
-- return shipping in addition to actual refunds.
-- ============================================================

PROMPT
PROMPT ===== QUERY 14: BRAND PERFORMANCE =====

COLUMN Brand FORMAT A20
COLUMN UnitsSold FORMAT 999990
COLUMN NetSales FORMAT 999999990.00
COLUMN WholesaleCost FORMAT 999999990.00
COLUMN AmazonFees FORMAT 9999990.00
COLUMN ShippingCost FORMAT 9999990.00
COLUMN ReturnCost FORMAT 9999990.00
COLUMN LineReturnRatePct FORMAT 990.00
COLUMN MissingCostLines FORMAT 999990
COLUMN EstimatedNetContribution FORMAT 999999990.00
COLUMN ContributionMarginPct FORMAT 999990.00

SELECT
    Brand,
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
    ROUND(SUM(LineReturnCost), 2) AS ReturnCost,
    ROUND(
        100 * SUM(ReturnedLine) / COUNT(*),
        2
    ) AS LineReturnRatePct,
    SUM(MissingCostLine) AS MissingCostLines,
    CASE
        WHEN SUM(MissingCostLine) = 0
            THEN ROUND(
                SUM(
                    NetSales
                    - LineWholesaleCost
                    - LineAmazonFees
                    - LineShippingCost
                    - LineReturnCost
                ),
                2
            )
    END AS EstimatedNetContribution,
    CASE
        WHEN SUM(MissingCostLine) = 0
            THEN ROUND(
                100 * SUM(
                    NetSales
                    - LineWholesaleCost
                    - LineAmazonFees
                    - LineShippingCost
                    - LineReturnCost
                ) / NULLIF(SUM(NetSales), 0),
                2
            )
    END AS ContributionMarginPct
FROM (
    SELECT
        Brand,
        Quantity,
        NetSales,
        LineWholesaleCost,
        AllocationShare * OrderAmazonFees AS LineAmazonFees,
        AllocationShare * OrderShippingCost AS LineShippingCost,
        LineReturnCost,
        ReturnedLine,
        MissingCostLine
    FROM (
        SELECT
            p.Brand,
            oi.Quantity,
            oi.Quantity * oi.SellingPricePerUnit
                - oi.Discount AS NetSales,
            oi.Quantity * AverageUnitCost AS LineWholesaleCost,
            ao.AmazonReferralCost + ao.SubscriptionCost
                AS OrderAmazonFees,
            ao.ShippingCost AS OrderShippingCost,
            NVL(r.RefundAmount, 0)
                + NVL(r.ReturnShippingCost, 0) AS LineReturnCost,
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
GROUP BY Brand
ORDER BY NetSales DESC, Brand;

-- Expected output (verified in Oracle Omega):
--
-- Brand              | UnitsSold | NetSales | WholesaleCost | AmazonFees | ShippingCost | ReturnCost | LineReturnRatePct | MissingCostLines | EstimatedNetContribution | ContributionMarginPct
-- Calvin Klein       | 9         | 823.41   | NULL          | 127.48     | 25.96        | 833.37     | 100.00            | 2                | NULL                     | NULL
-- The North Face     | 3         | 485.97   | 67.50         | 73.89      | 6.99         | 488.46     | 100.00            | 0                | -150.87                  | -31.05
-- Amazon Essentials  | 14        | 430.06   | NULL          | 69.46      | 42.95        | 440.02     | 100.00            | 1                | NULL                     | NULL
-- Lands' End         | 6         | 396.84   | NULL          | 61.51      | 13.98        | 401.82     | 100.00            | 1                | NULL                     | NULL
-- Columbia           | 5         | 359.95   | NULL          | 56.97      | 22.97        | 364.93     | 100.00            | 2                | NULL                     | NULL
-- Alpha Industries   | 2         | 251.98   | NULL          | 38.79      | 4.99         | 251.98     | 100.00            | 1                | NULL                     | NULL
-- Ever-Pretty        | 3         | 215.97   | NULL          | 33.39      | 8.99         | 218.46     | 100.00            | 1                | NULL                     | NULL
-- Hanes              | 8         | 205.12   | 205.00        | 35.72      | 36.95        | 212.59     | 100.00            | 0                | -285.14                  | -139.01
-- Levi's             | 3         | 197.97   | NULL          | 32.67      | 28.97        | 202.95     | 100.00            | 1                | NULL                     | NULL
-- CRZ Yoga           | 6         | 175.44   | 202.50        | 28.30      | 15.98        | 177.93     | 100.00            | 0                | -249.27                  | -142.08
-- The Drop           | 4         | 170.96   | NULL          | 27.63      | 19.98        | 173.45     | 100.00            | 1                | NULL                     | NULL
-- Dockers            | 5         | 170.95   | NULL          | 27.63      | 21.98        | 175.93     | 100.00            | 1                | NULL                     | NULL
-- Under Armour       | 4         | 143.96   | NULL          | 23.58      | 13.98        | 148.94     | 100.00            | 1                | NULL                     | NULL
-- Goodthreads        | 4         | 133.16   | 55.00         | 21.95      | 13.98        | 135.65     | 100.00            | 0                | -93.42                   | -70.16
-- Nike               | 3         | 125.97   | NULL          | 20.88      | 17.98        | 130.95     | 100.00            | 2                | NULL                     | NULL
-- ANRABESS           | 2         | 98.98    | 25.00         | 15.84      | 6.99         | 101.47     | 100.00            | 0                | -50.32                   | -50.84
-- Adidas             | 1         | 62.99    | NULL          | 10.44      | 4.99         | 62.99      | 100.00            | 1                | NULL                     | NULL
-- Fruit of the Loom  | 2         | 57.58    | NULL          | 10.61      | 15.98        | 62.56      | 100.00            | 1                | NULL                     | NULL
-- Champion           | 2         | 50.38    | 25.00         | 8.55       | 6.99         | 52.87      | 100.00            | 0                | -43.03                   | -85.41
-- Carhartt           | 2         | 41.38    | NULL          | 7.20       | 8.99         | 41.38      | 100.00            | 1                | NULL                     | NULL
-- Ekouaer            | 1         | 29.69    | 17.50         | 5.44       | 10.99        | 32.18      | 100.00            | 0                | -36.42                   | -122.67
-- Wrangler           | 1         | 29.69    | NULL          | 5.44       | 6.99         | 32.18      | 100.00            | 1                | NULL                     | NULL
--
-- 22 rows selected.
--
-- ============================================================
-- Query 15: Comparable-month demand forecast.
--
-- English question:
-- Based on sales in the same calendar month in previous years,
-- how many units of each product variant might be needed?
--
-- Business goal:
-- Goal 5: Seasonal Demand Forecasting Report.
--
-- Features:
-- Multiple JOINs, nested subqueries, GROUP BY, SUM, AVG,
-- COUNT, CASE, date functions, and ORDER BY.
--
-- Assumptions and limitations:
-- 1. The forecast covers the 12 months immediately following
--    the latest recorded order month, not the current date.
--
-- 2. ForecastUnits is the average quantity sold in the same
--    calendar month across available earlier years.
--    No growth or trend adjustment is applied.
--
-- 3. Historical months included in the calculation are assumed
--    to contain complete sales data.
--
-- 4. Variant/month combinations without comparable historical
--    sales are omitted. Missing history does not mean zero demand.
--    Months without recorded sales are not included as zeroes
--    in the historical average.
--
-- 5. PriorYearsUsed counts the earlier years contributing an
--    observed sales total for that variant and calendar month.
--
-- 6. The current sample provides only a ONE-YEAR BASELINE.
--    This demonstrates the forecasting calculation, but does
--    not establish a reliable recurring seasonal pattern.
--
-- 7. The calculation uses gross units ordered. Returns are not
--    deducted, and unmet demand during stockouts is unknown.
-- ============================================================

SET TAB OFF
SET SQLBLANKLINES ON
SET LINESIZE 220
SET PAGESIZE 100

PROMPT
PROMPT ===== QUERY 15: COMPARABLE-MONTH DEMAND FORECAST =====

COLUMN VariantID FORMAT 9999999990
COLUMN ProductName FORMAT A30
COLUMN ForecastMonth FORMAT A13
COLUMN PriorYearsUsed FORMAT 9999999999990
COLUMN ForecastUnits FORMAT 999999990.00
COLUMN DataStatus FORMAT A22

SELECT
    VariantID,
    ProductName,
    TO_CHAR(TargetMonth, 'YYYY-MM') AS ForecastMonth,
    PriorYearsUsed,
    ROUND(EstimatedUnits, 2) AS ForecastUnits,
    CASE
        WHEN PriorYearsUsed = 1
            THEN 'ONE-YEAR BASELINE'
        ELSE 'MULTI-YEAR BASELINE'
    END AS DataStatus
FROM (
    SELECT
        pv.VariantID,
        p.ProductName,
        TargetMonth,
        COUNT(HistoricalMonth) AS PriorYearsUsed,
        AVG(HistoricalUnits) AS EstimatedUnits
    FROM F26_S001_T5_PRODUCT_VARIANT pv
    JOIN F26_S001_T5_PRODUCT p
        ON p.ProductID = pv.ProductID
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
    GROUP BY
        pv.VariantID,
        p.ProductName,
        TargetMonth
)
WHERE PriorYearsUsed > 0
ORDER BY TargetMonth, VariantID;

-- Expected output (verified in Oracle Omega, current database):
--
-- VariantID | ProductName                    | ForecastMonth | PriorYearsUsed | ForecastUnits | DataStatus
-- 2001      | Classic Cotton T-Shirt         | 2027-03       | 1              | 2.00          | ONE-YEAR BASELINE
-- 2002      | Slim Fit Oxford Shirt          | 2027-03       | 1              | 3.00          | ONE-YEAR BASELINE
-- 2003      | Relaxed Fit Hoodie             | 2027-03       | 1              | 1.00          | ONE-YEAR BASELINE
-- 2004      | Performance Polo Shirt         | 2027-03       | 1              | 2.00          | ONE-YEAR BASELINE
-- 2005      | Ribbed Tank Top                | 2027-03       | 1              | 3.00          | ONE-YEAR BASELINE
-- 2006      | Straight Leg Jeans             | 2027-03       | 1              | 1.00          | ONE-YEAR BASELINE
-- 2007      | Slim Fit Chinos                | 2027-03       | 1              | 2.00          | ONE-YEAR BASELINE
-- 2008      | High Rise Leggings             | 2027-03       | 1              | 3.00          | ONE-YEAR BASELINE
-- 2009      | Cargo Shorts                   | 2027-04       | 1              | 1.00          | ONE-YEAR BASELINE
-- 2010      | Pleated Midi Skirt             | 2027-04       | 1              | 2.00          | ONE-YEAR BASELINE
-- 2011      | Floral Summer Dress            | 2027-04       | 1              | 3.00          | ONE-YEAR BASELINE
-- 2012      | Formal Wrap Dress              | 2027-04       | 1              | 1.00          | ONE-YEAR BASELINE
-- 2013      | Knit Sweater Dress             | 2027-04       | 1              | 2.00          | ONE-YEAR BASELINE
-- 2014      | Maxi Evening Dress             | 2027-04       | 1              | 3.00          | ONE-YEAR BASELINE
-- 2015      | Denim Shirt Dress              | 2027-04       | 1              | 1.00          | ONE-YEAR BASELINE
-- 2016      | Lightweight Windbreaker        | 2027-04       | 1              | 2.00          | ONE-YEAR BASELINE
-- 2017      | Puffer Winter Jacket           | 2027-05       | 1              | 3.00          | ONE-YEAR BASELINE
-- 2018      | Classic Denim Jacket           | 2027-05       | 1              | 1.00          | ONE-YEAR BASELINE
-- 2019      | Waterproof Raincoat            | 2027-05       | 1              | 2.00          | ONE-YEAR BASELINE
-- 2020      | Wool Blend Overcoat            | 2027-05       | 1              | 3.00          | ONE-YEAR BASELINE
-- 2021      | Fleece Jogger Pants            | 2027-05       | 1              | 1.00          | ONE-YEAR BASELINE
-- 2022      | Running Compression Shorts     | 2027-05       | 1              | 2.00          | ONE-YEAR BASELINE
-- 2023      | Yoga Sports Bra                | 2027-05       | 1              | 3.00          | ONE-YEAR BASELINE
-- 2024      | Training Track Jacket          | 2027-06       | 1              | 1.00          | ONE-YEAR BASELINE
-- 2025      | Workout Training Tee           | 2027-06       | 1              | 2.00          | ONE-YEAR BASELINE
-- 2026      | Cotton Pajama Set              | 2027-06       | 1              | 3.00          | ONE-YEAR BASELINE
-- 2027      | Satin Nightgown                | 2027-06       | 1              | 1.00          | ONE-YEAR BASELINE
-- 2028      | Fleece Lounge Pants            | 2027-06       | 1              | 2.00          | ONE-YEAR BASELINE
-- 2029      | Flannel Pajama Shirt           | 2027-06       | 1              | 3.00          | ONE-YEAR BASELINE
-- 2030      | Thermal Sleep Set              | 2027-06       | 1              | 1.00          | ONE-YEAR BASELINE
-- 2031      | Cotton Boxer Briefs            | 2027-06       | 1              | 2.00          | ONE-YEAR BASELINE
-- 2032      | Seamless Briefs                | 2027-07       | 1              | 3.00          | ONE-YEAR BASELINE
-- 2033      | Everyday Crew Socks            | 2027-07       | 1              | 1.00          | ONE-YEAR BASELINE
-- 2034      | Winter Knit Beanie             | 2027-07       | 1              | 2.00          | ONE-YEAR BASELINE
-- 2035      | Leather Casual Belt            | 2027-07       | 1              | 3.00          | ONE-YEAR BASELINE
-- 2036      | Linen Button-Up Shirt          | 2027-07       | 1              | 1.00          | ONE-YEAR BASELINE
-- 2037      | Oversized Graphic Tee          | 2027-07       | 1              | 2.00          | ONE-YEAR BASELINE
-- 2038      | Corduroy Trousers              | 2027-07       | 1              | 3.00          | ONE-YEAR BASELINE
-- 2039      | Athletic Running Leggings      | 2027-07       | 1              | 1.00          | ONE-YEAR BASELINE
-- 2040      | Quilted Bomber Jacket          | 2027-08       | 1              | 2.00          | ONE-YEAR BASELINE
-- 2041      | Cashmere Blend Sweater         | 2027-08       | 1              | 3.00          | ONE-YEAR BASELINE
-- 2042      | Cotton Henley Shirt            | 2027-08       | 1              | 1.00          | ONE-YEAR BASELINE
-- 2043      | Wide Leg Palazzo Pants         | 2027-08       | 1              | 2.00          | ONE-YEAR BASELINE
-- 2044      | Faux Leather Skirt             | 2027-08       | 1              | 3.00          | ONE-YEAR BASELINE
-- 2045      | Thermal Base Layer Top         | 2027-08       | 1              | 1.00          | ONE-YEAR BASELINE
--
-- 45 rows selected.
-- ============================================================
-- Query 16: Supplier credit and estimated savings
--
-- English question:
-- Which suppliers currently have active Net 30 status,
-- what are their credit limits and purchase histories,
-- and what savings would a 3.5 percent scenario imply?
--
-- Business Goal: 13
--
-- Features:
-- JOIN, aggregated subquery, GROUP BY,
-- SUM, CASE, calculated columns, ORDER BY.
-- ============================================================

PROMPT
PROMPT ===== QUERY 16: SUPPLIER CREDIT AND SAVINGS SUMMARY =====

COLUMN SupplierName FORMAT A30
COLUMN Net30Status FORMAT A11
COLUMN CreditLimit FORMAT 9999990.00
COLUMN PurchaseHistory FORMAT 999999990.00
COLUMN ReceivedPurchases FORMAT 999999990.00
COLUMN EstSavings FORMAT 9999990.00
COLUMN PotentialSavings FORMAT 9999990.00

SELECT
    s.SupplierID,
    s.SupplierName,
    s.Net30Status,
    s.CreditLimit,
    NVL(OrderedValue, 0) AS PurchaseHistory,
    NVL(ReceivedValue, 0) AS ReceivedPurchases,
    CASE
        WHEN s.Net30Status = 'Active'
            THEN ROUND(NVL(ReceivedValue, 0) * 0.035, 2)
        ELSE 0
    END AS EstSavings,
    CASE
        WHEN s.Net30Status = 'Inactive'
            THEN ROUND(NVL(ReceivedValue, 0) * 0.035, 2)
        ELSE 0
    END AS PotentialSavings
FROM F26_S001_T5_SUPPLIER s
LEFT JOIN (
    SELECT
        SupplierID AS PurchaseSupplierID,
        SUM(TotalCost) AS OrderedValue,
        SUM(
            CASE
                WHEN Status = 'Received'
                    THEN TotalCost
                ELSE 0
            END
        ) AS ReceivedValue
    FROM F26_S001_T5_PURCHASE_ORDER
    GROUP BY SupplierID
)
    ON PurchaseSupplierID = s.SupplierID
ORDER BY
    PotentialSavings DESC,
    EstSavings DESC,
    s.SupplierName;

-- Expected output (verified in Oracle Omega):
-- SupplierID | SupplierName                   | Net30Status | CreditLimit | PurchaseHistory | ReceivedPurchases | EstSavings | PotentialSavings
-- 28         | Lakeside Garment Wholesale      | Inactive    | 50000.00    | 800.00          | 800.00            | 0.00       | 28.00
-- 32         | Royal Thread Supply            | Inactive    | 20000.00    | 600.00          | 600.00            | 0.00       | 21.00
-- 8          | Urban Thread Wholesale         | Inactive    | 50000.00    | 600.00          | 600.00            | 0.00       | 21.00
-- 36         | Brightline Textile Group       | Inactive    | 40000.00    | 400.00          | 400.00            | 0.00       | 14.00
-- 12         | Silverline Clothing Supply     | Inactive    | 20000.00    | 400.00          | 400.00            | 0.00       | 14.00
-- 16         | Valley Knitwear Supply         | Inactive    | 40000.00    | 400.00          | 400.00            | 0.00       | 14.00
-- 23         | Prime Stitch Textiles          | Active      | 25000.00    | 2062.50         | 2062.50           | 72.19      | 0.00
-- 22         | Harbor Fashion Wholesale       | Active      | 20000.00    | 1750.00         | 1750.00           | 61.25      | 0.00
-- 7          | Coastal Denim Distributors     | Active      | 45000.00    | 1512.50         | 1512.50           | 52.94      | 0.00
-- 31         | Skyline Apparel Trading        | Active      | 15000.00    | 1512.50         | 1512.50           | 52.94      | 0.00
-- 21         | Sterling Garment Distributors  | Active      | 15000.00    | 1462.50         | 1462.50           | 51.19      | 0.00
-- 11         | Liberty Textile Trading        | Active      | 15000.00    | 1312.50         | 1312.50           | 45.94      | 0.00
-- 6          | Summit Fashion Supply          | Active      | 40000.00    | 1250.00         | 1250.00           | 43.75      | 0.00
-- 43         | Crown Apparel Wholesale        | Active      | 25000.00    | 962.50          | 962.50            | 33.69      | 0.00
-- 33         | Frontier Clothing Wholesale    | Active      | 25000.00    | 812.50          | 812.50            | 28.44      | 0.00
-- 42         | Global Stitch Partners         | Active      | 20000.00    | 750.00          | 750.00            | 26.25      | 0.00
-- 38         | Horizon Fashion Wholesale      | Active      | 50000.00    | 750.00          | 750.00            | 26.25      | 0.00
-- 18         | Westbrook Apparel Group        | Active      | 50000.00    | 750.00          | 750.00            | 26.25      | 0.00
-- 3          | Evergreen Fabric Distributors  | Active      | 25000.00    | 612.50          | 612.50            | 21.44      | 0.00
-- 27         | Meridian Textile Supply        | Active      | 45000.00    | 612.50          | 612.50            | 21.44      | 0.00
-- 17         | Atlantic Fashion Trading       | Active      | 45000.00    | 562.50          | 562.50            | 19.69      | 0.00
-- 37         | Capital Garment Supply         | Active      | 45000.00    | 562.50          | 562.50            | 19.69      | 0.00
-- 13         | Oakwood Fashion Distributors   | Active      | 25000.00    | 562.50          | 562.50            | 19.69      | 0.00
-- 41         | Riverside Textile Trading      | Active      | 15000.00    | 562.50          | 562.50            | 19.69      | 0.00
-- 26         | Brookfield Clothing Partners   | Active      | 40000.00    | 450.00          | 450.00            | 15.75      | 0.00
-- 2          | Golden State Apparel Supply    | Active      | 20000.00    | 450.00          | 450.00            | 15.75      | 0.00
-- 1          | Pacific Cotton Textiles        | Active      | 15000.00    | 312.50          | 312.50            | 10.94      | 0.00
-- 29         | Aspire Fashion Distributors    | Active      | 55000.00    | 1012.50         | 0.00              | 0.00       | 0.00
-- 5          | Blue Ridge Textile Group       | Active      | 35000.00    | 1012.50         | 0.00              | 0.00       | 0.00
-- 24         | Canyon Apparel Supply          | Inactive    | 30000.00    | 200.00          | 0.00              | 0.00       | 0.00
-- 30         | Cedar Valley Textiles          | Active      | 10000.00    | 1250.00         | 0.00              | 0.00       | 0.00
-- 45         | Continental Fashion Textiles   | Active      | 35000.00    | 1462.50         | 0.00              | 0.00       | 0.00
-- 19         | Crescent Textile Partners      | Active      | 55000.00    | 962.50          | 0.00              | 0.00       | 0.00
-- 34         | Diamond Fabric Partners        | Active      | 30000.00    | 1050.00         | 0.00              | 0.00       | 0.00
-- 40         | Elite Cotton Distributors      | Inactive    | 10000.00    | 400.00          | 0.00              | 0.00       | 0.00
-- 25         | Grandview Fabric Company       | Active      | 35000.00    | 312.50          | 0.00              | 0.00       | 0.00
-- 9          | Heritage Garment Supply        | Active      | 55000.00    | 812.50          | 0.00              | 0.00       | 0.00
-- 35         | Maple Grove Apparel            | Active      | 35000.00    | 1312.50         | 0.00              | 0.00       | 0.00
-- 14         | Metro Garment Wholesale        | Active      | 30000.00    | 750.00          | 0.00              | 0.00       | 0.00
-- 4          | Northstar Clothing Wholesale   | Inactive    | 30000.00    | 800.00          | 0.00              | 0.00       | 0.00
-- 15         | Pioneer Cotton Company         | Active      | 35000.00    | 962.50          | 0.00              | 0.00       | 0.00
-- 44         | Premier Garment Supply         | Inactive    | 30000.00    | 1200.00         | 0.00              | 0.00       | 0.00
-- 20         | Redwood Clothing Supply        | Inactive    | 10000.00    | 1200.00         | 0.00              | 0.00       | 0.00
-- 39         | Stonebridge Clothing Supply    | Active      | 55000.00    | 962.50          | 0.00              | 0.00       | 0.00
-- 10         | Sunrise Apparel Partners       | Active      | 10000.00    | 1050.00         | 0.00              | 0.00       | 0.00
--
-- 45 rows selected.

