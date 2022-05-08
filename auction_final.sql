/*
Stock Clearance - ADVENTUREWORKS
*/
USE AdventureWorks
GO

/*________________________________________________________________________________________________________
CREATE SCHEMA Auction
GO
*/
/*________________________________________________________________________________________________________
CREATE Tables for Auction schema */

IF OBJECT_ID ('[Auction].[Bid]', N'U') IS NOT NULL  
   DROP TABLE [Auction].[Bid];  
GO 
CREATE TABLE [Auction].[Bid]
	(
	[BidID] INT IDENTITY(1,1), 
    [UserID] INT NOT NULL, 
    [ProductID] INT NOT NULL, 
    [BidAmount] MONEY NOT NULL,
	[BidDate] DATETIME NOT NULL,
	[BidStatus] NVARCHAR(50) NULL,
	[Active] BIT NULL
	)
GO

IF OBJECT_ID ('[Auction].[Product]', N'U') IS NOT NULL  
DROP TABLE [Auction].[Product];
GO

CREATE TABLE [Auction].[Product]
	(
	[ProductID] INT NOT NULL PRIMARY KEY, 
    [Name] NVARCHAR(50) NULL, 
    [ProductNumber] NVARCHAR(25) NULL, 
    [InitialBidPrice] MONEY NOT NULL, 
	[MaximumBidPrice] MONEY NULL, 
    [StartDate] DATETIME NOT NULL, 
    [ExpireDate] DATETIME NOT NULL, 
    [StatusID] INT NULL
	)
GO

IF OBJECT_ID ('[Auction].[User]', N'U') IS NOT NULL  
DROP TABLE [Auction].[User];
GO

CREATE TABLE [Auction].[User]
	(
	[UserID] INT NOT NULL PRIMARY KEY, 
    [Name] NVARCHAR(50) NULL
	)
GO

-- Parameters table - Holds any required information to run the stored procedures
IF OBJECT_ID ('[Auction].[Parameters]', N'U') IS NOT NULL  
DROP TABLE [Auction].[Parameters];
GO

CREATE TABLE [Auction].[Parameters]
	(
	[Threshold] MONEY NOT NULL,
	[MaxBid] DECIMAL NOT NULL DEFAULT 100,
	[SetBy] NVARCHAR(50) NOT NULL DEFAULT SYSTEM_USER,
	[DateSet] DATETIME NOT NULL DEFAULT GETDATE()
	)
GO
INSERT INTO [Auction].[Parameters] ([Threshold])
VALUES (0.05)
GO

-- Sales table
IF OBJECT_ID ('[Auction].[Sales]', N'U') IS NOT NULL  
DROP TABLE [Auction].Sales;
GO

CREATE TABLE [Auction].Sales
	(
	[ProductID] INT NOT NULL, 
    [Name] NVARCHAR(50) NULL, 
    [ProductNumber] NVARCHAR(25) NULL, 
    [InitialBidPrice] MONEY NOT NULL, 
    [FinalBidPrice] MONEY NULL, 
    [StartDate] DATETIME NOT NULL, 
    [ExpireDate] DATETIME NOT NULL, 
    [StatusID] NVARCHAR(10) NULL,
	[AuctionEndDate] DATETIME NOT NULL
	)
GO

/*
New approach involving an online auction covering all products for which a new model was expected to be 
announced in the next 2 weeks. For products covered in this campaign the initial bid price varies from 
50% to 75% of listed price.
Only products that are currently commercialized (both SellEndDate and DiscontinuedDate values not set).
- Initial bid price for products that are not manufactured in-house (MakeFlag value is 0) should be
75% of listed price.
- For all other products initial bid prices should start at 50% of listed price.
- By default, users can only increase bids by 5 cents (minimum increase bid) with maximum bid limit
that is equal to initial product listed price. These thresholds should be easily configurable within a
table so no need to change database schema model. Note: These thresholds should be global and not per 
product/category.
*/

/*
________________________________________________________________________________________________________

-- Stored procedure name: uspAddProductToAuction
________________________________________________________________________________________________________
*/
CREATE OR ALTER PROCEDURE [Auction].[uspAddProductToAuction]
/*
Parameters: @ProductID [int], @ExpireDate [datetime], @InitialBidPrice [money]

Description: This stored procedure adds a product to be auctioned. These products are currently being 
commercialized where SellEndDate and DiscontinuedDate are NULL. This will populate the Auction.Product table.

Notes: Either @ExpireDate and @InitalBidPrice are optional parameters. If @ExpireDate is not specified, then 
the auction should end in one week. The stored procedure will say that the date was set to default.
If @InitialBidPrice, is not specified, this should be 50% of product listed if it was manufactured in-house 
and 75% if not, meaning, where MakeFlag equal to 0 and 1 respectively. If the @InitialBidPrice is missing or 
was invalid, meaning not between @MinimumBidPrice and @MaximumBidPrice then a message will be displayed saying 
that the value was set to default.
Only one item for each ProductID can be simultaneously enlisted in an auction.
The @MaximumBidPrice is set based on the parameters table, where MaxBid = 100% by default. There is a stored 
procedure to update this percentage uspUpdateMaxBid describe later.	  

Assumptions:  If we try to insert a product with ListPrice in Production.Product = 0 it won't allow it. This is 
to avoid listing products with no price, in order for these products to be added to auction we should amend the 
Production.Product table first. Also, Expiration dates accepted are only dates within the interval [3, 7] days, 
else will be 7 days by default. This would allow a decent amount of time for an auction.
If a product was sold, this should have been stored in the Auction.Sales table and the stored procedure also 
checks if the product is on that table and if it was actually sold. If it was sold you will not be able to add it
again for action. However, if the product was unsold it will execute the uspRemoveProductFromSales and the product 
now be added or reenlisted.

Usage: EXEC [Auction].[uspAddProductToAuction] @ProductID = 516 , @InitialBidPrice = 100, @ExpireDate= '2022-04-29'
*/
	@ProductID INT,
	@InitialBidPrice MONEY = NULL,
	@ExpireDate DATETIME = NULL

AS 

BEGIN	
-- If ProductID doesn't exists in the Production.Product table under the correct assumptions it will raise an error
IF NOT EXISTS 
	(
	SELECT [ProductID] FROM [Production].[Product]
	WHERE [SellEndDate] IS NULL and [DiscontinuedDate] IS NULL AND [ProductID] = @ProductID
	)
	BEGIN
		DECLARE @msg0 VARCHAR(500)
		SELECT @msg0 = 'ProductID = '+ CONVERT(VARCHAR, @ProductID) + ' cannot be added to auction.'
		RAISERROR (@msg0, 0, @ProductID)
	END
ELSE IF EXISTS 
	(
	SELECT [ProductID] FROM [Auction].[Sales]
	WHERE StatusID = 'SOLD' AND [ProductID] = @ProductID
	)
	BEGIN
		DECLARE @msg2 VARCHAR(500)
		SELECT @msg2 = 'ProductID = '+ CONVERT(VARCHAR, @ProductID) + ' cannot be added to auction, because it was sold.'
		RAISERROR (@msg2, 0, @ProductID)
	END
ELSE IF EXISTS 
	(
	SELECT [ProductID] FROM [Auction].[Sales]
	WHERE StatusID = 'UNSOLD' AND [ProductID] = @ProductID
	)
	BEGIN
		EXEC [Auction].[uspRemoveProductFromSales] @ProductId = @ProductID
	END
-- Error will be raised if we try to list a product with ListPrice = 0 in the Prodution.Product table
ELSE 
	IF (SELECT [ListPrice] FROM  [Production].[Product] WHERE [ProductID] = @ProductID) = 0
		BEGIN
			DECLARE @msg1 VARCHAR(500)
			SELECT @msg1 = 'ProductID = '+ CONVERT(VARCHAR, @ProductID) + ' has an invalid ListPrice of zero and must be updated before sending to auction.'
			RAISERROR (@msg1, 0, @ProductID)
		END

	ELSE
		BEGIN
			DECLARE @MinimumBidPrice MONEY
			SET @MinimumBidPrice = 
				(
				SELECT 
					CASE
						WHEN [MakeFlag] = 1 THEN [ListPrice] * 0.5
						ELSE [ListPrice] * 0.75
					END AS DefaultInitialBidPrice
				FROM [Production].[Product]
				WHERE [SellEndDate] IS NULL AND [DiscontinuedDate] IS NULL AND [ProductID] = @ProductID
				)
			DECLARE @MaxBid DECIMAL, @MaximumBidPrice AS MONEY
			SET @MaxBid = (SELECT [MaxBid] FROM Auction.Parameters)

			SET @MaximumBidPrice = 
				(
				SELECT [ListPrice] * @MaxBid/100 AS MaximumBidPrice FROM [Production].[Product]
				WHERE [SellEndDate] IS NULL AND [DiscontinuedDate] IS NULL AND [ProductID] = @ProductID
				)

			DECLARE @StartDate AS DATETIME SET @StartDate = GETDATE()

			-- Expiration dates accepted are only dates within the interval [3, 7] days, else will be 7 days by default
			IF (SELECT CASE
					--WHEN DATEADD(DAY,3, GETDATE()) < @expiredate AND DATEADD(DAY,7, GETDATE()) > @expiredate THEN 1
					WHEN @expiredate BETWEEN DATEADD(DAY,3, GETDATE()) AND DATEADD(DAY,7, GETDATE()) THEN 1
					ELSE 0
				END AS DateValidation) = 1
				
				BEGIN
					IF @InitialBidPrice NOT BETWEEN @MinimumBidPrice AND @MaximumBidPrice or @InitialBidPrice IS NULL
						BEGIN
							PRINT('Message:  Initial bid price is missing or is invalid. Set to default')
								-- Set initial bid based on ListPrice and on MakeFlag
							SET @InitialBidPrice = @MinimumBidPrice
						END
						INSERT INTO [Auction].[Product] ([ProductID], [InitialBidPrice], [MaximumBidPrice], [StartDate], [ExpireDate])
						VALUES (@ProductID, @InitialBidPrice, @MaximumBidPrice, @StartDate, @ExpireDate)
						PRINT('Message: Auction end date within the allowed 3 to 7 days interval')				
				END	
			ELSE
				BEGIN
					SET @ExpireDate = DATEADD(DAY,7,GETDATE())
					PRINT('Message: Default auction expiration date used')
				
					IF @InitialBidPrice NOT BETWEEN @MinimumBidPrice AND @MaximumBidPrice or @InitialBidPrice IS NULL
						BEGIN
							PRINT('Message: Initial bid price is missing or is invalid. Set to default')
							SET @InitialBidPrice = @MinimumBidPrice
						END
					INSERT INTO [Auction].[Product] ([ProductID],[InitialBidPrice], [MaximumBidPrice], [StartDate], [ExpireDate])
					VALUES (@ProductID, @InitialBidPrice, @MaximumBidPrice, @StartDate, @ExpireDate)
				END
		END
END
GO

/*
___________________________________________________________________________________________________________________________

-- Stored procedure name: uspTryBidProduct
___________________________________________________________________________________________________________________________
*/
CREATE OR ALTER PROCEDURE [Auction].[uspTryBidProduct]
/*
Parameters: @ProductID [int], @CustomerID [int], @BidAmount [money]

Description: This stored procedure adds bid on behalf of the customer

Notes:  @BidAmount is an optional parameter. If @BidAmount is not specified, then increase by threshold specified in Parameters
configuration table. This amount can be changed by using uspUpdateThreshold.
If a product is not on the Auction.Product table we cannot bid on that product. The are also some checks if we try to bid on a 
product and the bid date is after the auction end date. This will execute the uspRemoveProductFromAuction and raise an error 
stating that that product is no longer on auction.
If any bid is below the @MinimumBid (InitialBidPrice) or the actual current bid it will raise an error stating that and displaying 
the actual amount we will need to bid.
When inserting a bid, the uspTryBidProduct will always execute another stored procedure called uspUpdateProductAuctionStatus which 
will update all the status for all products. This will be described with further details on this document.

Assumptions: If @BidAmount is greater or equal than @MaximumBidPrice, we set bid to MaximumBidPrice. When this happens, that user 
wins the auction and the product is automatically removed from auction by executing the uspRemoveProductFromAuction.

Usage: EXEC [Auction].[uspTryBidProduct] @ProductID = 888 , @CustomerID = 701, @BidAmount = 540
*/
	@ProductID INT,
	@BidAmount MONEY = NULL,
	@CustomerID INT,
	@BidDate  DATETIME = NULL,
	@BidStatus NVARCHAR(5)= Null

AS 

BEGIN	
-- Default value for bid increase stored in the parameters table. To update this value:
-- Run EXEC [Auction].[uspUpdateThreshold] @Threshold = #NewThreshold 
DECLARE @Threshold AS MONEY
SET @Threshold = (SELECT [Threshold] FROM [Auction].[Parameters])

-- Retrive the minimum bid allowed for each product by finding the max bid and compare with the initial bid
DECLARE @MinimumBid AS MONEY
SET @MinimumBid = 
	(
	SELECT MAX(MinimumBid) + @Threshold AS MinimumBid FROM 
		(
		SELECT InitialBidPrice AS MinimumBid FROM [Auction].[Product] WHERE [ProductID] = @ProductID
		UNION ALL
		SELECT BidAmount FROM [Auction].[BID] WHERE [ProductID] = @ProductID
		) AS BidAmounts
	)

DECLARE @EndDate AS DATETIME
SET @EndDate = (SELECT [ExpireDate] FROM  [Auction].[Product] WHERE [ProductID] = @ProductID)

-- Retrieves the ListedPrice of a product to ensure no bids are made over that price
DECLARE @MaximumBidPrice AS MONEY
SET @MaximumBidPrice = (SELECT [MaximumBidPrice] FROM [Auction].[Product] WHERE ProductID = @ProductID)

SET @BidDate = GETDATE()

-- If ProductID doesn't exists in the Auction.Product table it will raise an error
IF NOT EXISTS 
	(
	SELECT ProductID FROM [Auction].[Product] WHERE [ProductID] = @ProductID
	)
	BEGIN
		DECLARE @msg1 VARCHAR(500)
		SELECT @msg1 = 'ProductID = '+ CONVERT(VARCHAR, @ProductID) + ' is not on auction. Bid is invalid.'
		RAISERROR (@msg1, 0, @ProductID)
	END

-- Raise error if the bid date is greather than the auction end date and remove product from auction
ELSE IF @BidDate > @EndDate
	BEGIN
		EXEC [Auction].[uspRemoveProductFromAuction] @ProductId = @ProductId

		DECLARE @msg3 VARCHAR(500)
		SELECT @msg3 = 'Auction has ended for ProductID = '+ CONVERT(VARCHAR, @ProductID) + '. Bid is invalid.'
		RAISERROR (@msg3, 0, @ProductID)
	END

-- bid amount has to be higher than the minimum bid allowed
ELSE IF @BidAmount < @MinimumBid
	BEGIN
		DECLARE @msg2 VARCHAR(500)
		SELECT @msg2 = 'Current bid is = '+ CONVERT(VARCHAR, @MinimumBid-0.5,2) + '. Please bid at least = ' + CONVERT(VARCHAR, @MinimumBid)
		RAISERROR (@msg2, 0, @MinimumBid)
	END

-- Bid amount can't be higher than the listed price
ELSE IF @BidAmount >= @MaximumBidPrice
	BEGIN
		SET @BidAmount = @MaximumBidPrice		

		INSERT INTO [Auction].[Bid]	([UserID], [ProductID], [BidAmount], [BidDate], [BidStatus])
		VALUES ( @CustomerID, @ProductID, @BidAmount, @BidDate, @BidStatus)

		EXEC  [Auction].[uspRemoveProductFromAuction] @ProductId = @ProductID
	END
ELSE IF @BidAmount IS NULL
	BEGIN
		SET @BidAmount = @MinimumBid
	
		IF @BidAmount >= @MaximumBidPrice
			BEGIN
				SET @BidAmount = @MaximumBidPrice
				INSERT INTO [Auction].[Bid]	([UserID], [ProductID], [BidAmount], [BidDate], [BidStatus])
				VALUES ( @CustomerID, @ProductID, @BidAmount, @BidDate, @BidStatus)

				EXEC [Auction].[uspRemoveProductFromAuction] @ProductId = @ProductID
			END
		ELSE
			BEGIN
				INSERT INTO [Auction].[Bid]	([UserID], [ProductID], [BidAmount], [BidDate], [BidStatus])
				VALUES ( @CustomerID, @ProductID, @BidAmount, @BidDate, @BidStatus)
				
				EXEC [Auction].[uspUpdateProductAuctionStatus]
			END
	END
ELSE		
	BEGIN	
		INSERT INTO [Auction].[Bid]	([UserID], [ProductID], [BidAmount], [BidDate], [BidStatus])
		VALUES ( @CustomerID, @ProductID, @BidAmount, @BidDate, @BidStatus)

		EXEC [Auction].[uspUpdateProductAuctionStatus]
	END
END
GO


/*
______________________________________________________________________________________________________________________________

-- Stored procedure name: uspRemoveProductFromAuction
______________________________________________________________________________________________________________________________
*/
CREATE OR ALTER PROCEDURE [Auction].[uspRemoveProductFromAuction]
/*
Parameters: @ProductID [int]

Description: Removes a product from being listed as auctioned even when there might have been bids for that product. Add the removed 
product to the Auction.Sales table with the final bid (sold value).

Notes: When users are checking their bid history this product should also show up as auction cancelled.
This will execute Auction.uspUpdateProductAuctionStatus and we will have updated status on the bids.
If a product isn’t sold this stored procedure will flag this product as unsold on the Auction.Sales table and it will be eligible for 
being reenlisted by uspAddProductToAction.

Assumptions: Assuming that we can't remove a product until the auction times ends. 
The previous assumption is ignored if the user has won the bid by bidding an amount higher than the maximum bid. This store procedure 
is executed inside the uspTryBidProduct.

Usage:	EXEC [Auction].[uspRemoveProductFromAuction] @ProductId = 792
*/
	@ProductID INT

AS 

BEGIN

DECLARE @AuctionEndDate DATETIME 
SET @AuctionEndDate = GETDATE()

DECLARE @ExpireDate DATETIME 
SET @ExpireDate = (SELECT [ExpireDate] FROM [Auction].[Product] WHERE [ProductID] = @ProductID)

DECLARE @MaximumBidPrice AS MONEY
SET @MaximumBidPrice = (SELECT [MaximumBidPrice] FROM [Auction].[Product] WHERE ProductID = @ProductID)

DECLARE @BidAmount AS MONEY
SET @BidAmount = (SELECT MAX([BidAmount]) FROM [Auction].[Bid] WHERE ProductID = @ProductID)

DECLARE @StatusID VARCHAR(10)
SET @StatusID = 'SOLD'
DECLARE @FinalBid MONEY
--  If ProductID doesn't exists in the Auction.Product table it will raise an error
IF NOT EXISTS (SELECT [ProductID] FROM [Auction].[Product] WHERE ProductID = @ProductID)
	BEGIN
		DECLARE @msg4 VARCHAR(500)
		SELECT @msg4 = 'ProductID = ' + CONVERT(VARCHAR, @ProductID) + ' is not on auction. Cannot remove product.'
		RAISERROR (@msg4, 0, @ProductID)
	END
-- Transfer item from Product to Sales table and update product status 
ELSE IF	@AuctionEndDate	>= @ExpireDate

	BEGIN
		SET @FinalBid = (SELECT MAX(BidAmount) AS WinnerBid FROM [Auction].[Bid] WHERE [ProductID] = @ProductID)

		IF @FinalBid IS NULL
			SET @StatusID = 'UNSOLD'

		-- Storing sold item onto Sales table
		INSERT INTO Auction.Sales 
		([ProductID], [Name], [ProductNumber], [InitialBidPrice], [FinalBidPrice], [StartDate], [ExpireDate], [StatusID], [AuctionEndDate])
		(
		SELECT 
			[ProductID], [Name], [ProductNumber], [InitialBidPrice], @FinalBid,[StartDate], [ExpireDate], @StatusID, @AuctionEndDate
		FROM [Auction].[Product] WHERE [ProductID] = @ProductID
		)
		
		-- Removing product from auction
		DELETE FROM Auction.Product WHERE [ProductID] = @ProductID
		
		EXEC [Auction].[uspUpdateProductAuctionStatus]
	END

ELSE IF @AuctionEndDate	< @ExpireDate AND @BidAmount = @MaximumBidPrice
	BEGIN
		--DECLARE @FinalBid MONEY
		SET @FinalBid = @MaximumBidPrice
		SET @StatusID = 'SOLD'
		-- Storing sold item onto Sales table
		INSERT INTO Auction.Sales 
		([ProductID], [Name], [ProductNumber], [InitialBidPrice], [FinalBidPrice], [StartDate], [ExpireDate], [StatusID], [AuctionEndDate])
		(
		SELECT 
			[ProductID], [Name], [ProductNumber], [InitialBidPrice], @FinalBid,[StartDate], [ExpireDate], @StatusID, @AuctionEndDate
		FROM [Auction].[Product] WHERE [ProductID] = @ProductID
		)
		
		-- Removing product from auction, since it is already in the sales ta
		DELETE FROM Auction.Product WHERE [ProductID] = @ProductID
		
		EXEC [Auction].[uspUpdateProductAuctionStatus]
	END
ELSE 
	BEGIN
		DECLARE @msg5 VARCHAR(500)
		SELECT @msg5 = 'ProductID = ' + CONVERT(VARCHAR, @ProductID) + ' still has ' 
						+ CONVERT(VARCHAR, DATEDIFF(HOUR, @AuctionEndDate, @ExpireDate)) + ' remaining hours till auction ends. Product will not be removed.'
		RAISERROR (@msg5, 0, @ProductID)
	END
END
GO

/*
______________________________________________________________________________________________________________________________

-- Stored procedure name: uspListBidsOffersHistory
______________________________________________________________________________________________________________________________
*/
CREATE OR ALTER PROCEDURE [Auction].[uspListBidsOffersHistory]
/*
Parameters: @CustomerID [INT], @StartTime [DATETIME], @EndTime [DATETIME], @Active [Boolean]

Description: This stored procedure returns customer bid history for specified date time interval. If Active parameter is set to 
false, then all bids should be returned, including ones related for products no longer auctioned or purchased by customer. 
If Active set to true (default value) only returns products currently auctioned.

Notes: 	@Active is Boolean so it accepts 1, 0, TRUE and FALSE.

Assumptions: CustomerID needs to be provided. If no @StartTime is provide we will assume a search for the past week based on @EndTime. 
If no @EndTime is provided we assume current date(GETDATE()) as default. Note that we will be providing dates with the time part set 
to zero and how this interacts with GETDATE().

Usage: EXEC [Auction].[uspListBidsOffersHistory] @CustomerID= 801, @Active = 1	
EXEC [Auction].[uspListBidsOffersHistory] @CustomerID= 801, @StartTime= '2022-04-23' , @EndTime = '2022-04-27', @Active = 'FALSE'
EXEC [Auction].[uspListBidsOffersHistory] @CustomerID= 801,  @Active = 'FALSE'
*/
	@CustomerID INT = NULL,
	@StartTime DATE = NULL,
	@EndTime DATE = NULL,
	@Active BIT = 1

AS

DECLARE  @True AS BIT, @False AS BIT

-- Set filters for Active and non Active bid searchs
BEGIN
IF @Active = 'TRUE'
    BEGIN
    SET @True  = 1 
    SET @False = 1
    END
ELSE
    BEGIN
    SET @True  = 1 
    SET @False = 0
    END

 -- @Confirm if CustomerID is on the Auction.Bid table and raises an error
IF NOT EXISTS (SELECT [UserID] From [Auction].[Bid] WHERE UserID = @CustomerID)
	BEGIN
		DECLARE @msg6 VARCHAR(500)
		SELECT @msg6 = 'No auction details for CurstomerID = ' + CONVERT(VARCHAR, @CustomerID) + '. Confirm CustomerID and try again.'
		RAISERROR (@msg6, 0, @CustomerID)
	END
-- Next 2 conditions check for intervals provided and return apropriate messages
ELSE IF @EndTime < @StartTime
	BEGIN
		DECLARE @msg7 VARCHAR(500)
		SELECT @msg7 = 'Confirm search interval. EndTime is greather than StartTime.'
		RAISERROR (@msg7, 0,@CustomerID)
	END
ELSE IF @StartTime > GETDATE()
	BEGIN
		DECLARE @msg8 VARCHAR(500)
		SELECT @msg8 = 'Confirm search interval. StartTime is set after current date.'
		RAISERROR (@msg8, 0,@CustomerID)
	END
-- Search queries depending on the search dates provided - Sets appropriate defaults
ELSE
	BEGIN
		IF	@StartTime IS NULL
			SET @StartTime = CAST(DATEADD(DAY,-7,GETDATE()) AS DATE)
		IF	@EndTime IS NULL
			SET @EndTime = CAST(GETDATE() AS DATE)
		
		SELECT * FROM [Auction].[Bid] WHERE [BidDate] Between @StartTime AND @EndTime and [UserID] = @CustomerID
		AND ([Active] = @True OR [Active] = @False)
	END
END
GO

/*
______________________________________________________________________________________________________________________________

-- Stored procedure name: uspUpdateProductAuctionStatus
______________________________________________________________________________________________________________________________
*/

CREATE OR ALTER PROCEDURE [Auction].[uspUpdateProductAuctionStatus]
/*
Parameters: None

Description: This stored procedure updates auction status for all auctioned products. This stored procedure can be manually 
invoked or invoked within other stored procedures.

Notes: Updates @BidStatus on Auction.Bid table with 4 Status: Win, Lost, Winning, Loosing. This facilitates interpretation. 
Also, sets Active on that same table to either 1 or 0, i.e., True or False (Boolean). The active parameter set to True means 
the auction is live and the BidStatus is either winning or loosing, if False BidStatus will be set to win or loose.

Usage: EXEC [Auction].[uspUpdateProductAuctionStatus]
*/
AS

BEGIN

;WITH WinningBid_CTE AS (
    SELECT 
        ProductID, MAX(BidAmount) AS WinningBid
    FROM [Auction].[BID]
    GROUP BY ProductID
    )
, Status_CTE AS (
	SELECT
	    b.BidID, w.WinningBid,
	    CASE
	        WHEN b.[BidAmount] = s.[FinalBidPrice] THEN 'Win'
	        WHEN b.[BidAmount] = w.[WinningBid] THEN 'Winning'
	        WHEN l.[ProductId] IS NOT NULL and w.[WinningBid] IS NULL THEN 'Lost'
	        ELSE 'Losing'
	    END AS [UpdatedBidStatus],
		CASE
	        WHEN b.[BidAmount] = s.[FinalBidPrice] THEN 0
	        WHEN b.[BidAmount] = w.[WinningBid] THEN 1
	        WHEN l.[ProductId] IS NOT NULL and w.[WinningBid] IS NULL THEN 0
	        ELSE 1
	    END AS [UpdatedActive]
	FROM [Auction].[BID] AS b
	LEFT JOIN WinningBid_CTE AS w
	    ON b.[ProductID] = w.[ProductID] AND b.BidAmount = w.WinningBid
	LEFT JOIN [Auction].[Sales] AS s
	    ON b.[ProductID] = s.[ProductID] AND b.BidAmount = s.FinalBidPrice
	LEFT JOIN [Auction].[Sales] AS l
	    ON b.[ProductID] = l.[ProductID]
	)
UPDATE b
	SET b.[BidStatus] = s.[UpdatedBidStatus],
		b.[Active] = s.[UpdatedActive]
FROM [Auction].[Bid] b
left join Status_CTE s
	ON b.BidID = s.BidID
END
GO

/*
________________________________________________________________________________________________________

-- Stored procedure name: uspUpdateThreshold
________________________________________________________________________________________________________
*/
CREATE OR ALTER PROCEDURE [Auction].[uspUpdateThreshold]
/*
Parameters:  @Threshold  [INT]

Description: Changes the default bid increase.

Notes: There is no restriction to the Threshold that can be set. Will also records the user who makes the 
last update and records the actual date and time.

Assumptions: Assumed that the user would input a valid number.

Usage: 	EXEC [Auction].[uspUpdateThreshold] @Threshold = 1.00
*/
	@Threshold INT = 0.5

AS 

BEGIN	

UPDATE [Auction].[Parameters]
	SET [Threshold] = @Threshold,
		[SetBy] = SYSTEM_USER,
		[DateSet] = GETDATE()
END
GO

/*
________________________________________________________________________________________________________

-- Stored procedure name: uspUpdateMaxBid
________________________________________________________________________________________________________
*/
CREATE OR ALTER PROCEDURE [Auction].[uspUpdateMaxBid]
/*
Parameters:  @MaxBid  [INT]

Description: Changes the default maximum bid accepted for an item (percentage).

Notes: There is no restriction to the MaxBid that can be set. Will also records the user who makes the update 
and records the actual date and time.

Assumptions: Assumed that the user would input a valid percentage, by default this should be 100%. We could 
have added restrictions to the stored procedure which should have been implemented in a real case scenario 
based on a specification by a client.

Usage: EXEC [Auction].[uspUpdateThreshold] @MaxBid = 120 -- 120%
*/

	@MaxBid INT = 100

AS 

BEGIN	

UPDATE [Auction].[Parameters]
	SET [MaxBid] = @MaxBid,
		[SetBy] = SYSTEM_USER,
		[DateSet] = GETDATE()
END
GO

/*
______________________________________________________________________________________________________________________________

-- Stored procedure name: uspRemoveProductFromSales
______________________________________________________________________________________________________________________________
*/
CREATE OR ALTER PROCEDURE [Auction].[uspRemoveProductFromSales]
/*
Parameters: @ProductID [int]

Description: Removes a product from auction sales where no bids where made for that product.
		This stored procedure is executed when reenlisting the product by the uspAddProductToAuction.

Notes: 
		None
		
Assumptions:
		We remove from Auction.Sales if status ID is UNSOLD

Usage:
		EXEC [Auction].[uspRemoveProductFromSales] @ProductId = 792

*/
	@ProductID INT

AS 

BEGIN
	DELETE FROM Auction.Sales WHERE [ProductID] = @ProductID
END
GO
/*______________________________________________________________________________________________________

Deliverables:
- T-SQL script file named auction.sql used to extended AdventureWorks database schema

Notes:
- T-SQL script should be idempotent. Assume that database this script will execute against is named AdventureWorks.
- T-SQL script should also pre-populate any required configuration tables with default values.
- Being idempotent this population should be just performed once no matter how many times T-SQL script is executed.
- Even not explicitly mentioned all stored procedures should have proper error/exception handling mechanism.
*/
