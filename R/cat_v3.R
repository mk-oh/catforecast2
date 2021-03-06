#' The analysis using Catboost
#'
#'\code{cat.forecast2} Analysis/Forecast Using Catboost. _Add non-selling cnt
#'
#' @param y input time-seires vector
#' @param h forecast preiod
#' @param xreg External Variable for using modeling (need to matrix class)
#' @param pred_xreg External Variable for using forecast (need to matrix class )
#' @param maxlag data lag length
#' @param valid Validation (TRUE / FALSE)
#' @param boxcox boxcox (TRUE / FALSE)
#' @param ts_clean clean Outlier (TRUE / FALSE)
#' @param ts_lambda lambda with clean Outlier
#' @param season_type treat a Type of season ('dummy', "decompose", "none")
#'
#' @return time-seires data forecast
#'
#' @export
#'
#' @examples
#' cat.forecast2(AirPassengers)

cat.forecast2 <- function (y,
                          h = 42,
                          xreg = NULL,
                          pred_xreg = NULL,
                          params = NULL,
                          maxlag = max(42, 4 * frequency(y)),
                          valid = TRUE,
                          #- Data preprocess
                          # log = TRUE,
                          boxcox = TRUE,
                          ts_clean = TRUE,
                          lambda = BoxCox.lambda(y),
                          season_type = c("dummy", "decompose", "none"),
                          verbose = TRUE, ...)  {

  season_type = match.arg(season_type)

  #---- Check Data format
  if (!"ts" %in% class(y)) {
    stop("y class check : y need to ts class")
  }

  if (length(y) < maxlag){
    stop('Data is too short')
  }

    if (!is.null(xreg)) {
      xreg <- as.matrix(xreg)
      if (!is.numeric(xreg) | !is.matrix(xreg)) {
        stop("xreg check : class is numeric vector or a matrix")
      }
    }

  oriny <- y

  #---- Making Non-selling Data
  non_sale <- ifelse(as.vector(y) == 0 , 1 , 0) # checking non_date

  non_sale_day <- NA

  for ( i in 1L : length(y) ){
    if ( i <= 21L  ) { # priod +1
      non_sale_day[i] <- sum(non_sale[c(1L : i)] , na.rm =T)
    } else {
      non_sale_day[i] <- sum(non_sale[c((i - 21L) : i) ] , na.rm =T) # priod
    }
  }
  non_sale_day <- non_sale_day[-c(1:maxlag)]


  #### Outlier preprocess - (require : forecast package)
  if(ts_clean == TRUE) {
    y <- tsclean(y, lambda)
  }

  y_temp <- y
  origxreg <- xreg

  f <- stats::frequency(y)
  orig_n <- length(y)

  #### Check a length of y
  if (orig_n < 46L) {
    stop("must be data length > 45")
  }


  #### Check Maxlag period / trans.

  if (maxlag > (orig_n - f )) {
    warning(paste("y is too short ", maxlag, "-> ",
                  orig_n - f - round(f/2)))
    maxlag <- orig_n - f - round(f/2)
  }

  #### Log Translate  ---->  Crush...

  # if (log == TRUE) {
  #   y <- log1p(y)
  # }

  #### BoxCox Translate  (require : forecast package )
  if (boxcox == FALSE){
    lambda = 1
  }

  target_y <- Boxcox(y, lambda = lambda)


  if (maxlag != round(maxlag)) {
    maxlag <- round(maxlag)
    if (verbose) {
      message(paste("maxlag is need to int, change to ", maxlag))
    }
  }


  if (season_type == "decompose") {
    decomp <- decompose(target_y, type = "multiplicative")
    target_y <- seasadj(decomp)

  }


  n <- orig_n - maxlag

  # Target split -> y range : [1 ~ maxlag]
  y2 <- ts(target_y[-(1:(maxlag))],
           start = time(target_y)[maxlag + 1],
           frequency = f)

  if (season_type == "dummy" & f > 1) {
    ncolx <- maxlag + f - 1
  }

  if (season_type == "decompose" | (season_type == "none" | f == 1)) {
    ncolx <- maxlag
  }


  #---- make time lag

  x <- matrix(0, nrow = n, ncol = ncolx)
  x[, 1:maxlag] <- lag_y(target_y, maxlag)


  if (f == 1 || season_type == "decompose" || season_type == "none") {
    colnames(x) <- c(paste0("lag", 1:maxlag))
  }


  if (f > 1 & season_type == "dummy") {
    tmp <- data.frame(y = 0,
                      x = as.character(rep_len(1:f, n))
    )
    seasons <- stats::model.matrix(y ~ x, data = tmp)[, -1]
    x[, maxlag + 1:(f - 1)] <- seasons
    colnames(x) <- c(paste0("lag", 1:maxlag),
                     paste0("season", 2:f))
  }


  x <- cbind( x, non_sale_day )

  if (!is.null(xreg)) {
    x <- cbind(x, origxreg[-c(1:maxlag),] )
  }



###############################################################


###############################################################

  #---- Make temp data
  x_temp <- x    # timelag + xreg
  y2_temp <- y2  # splitted y (maxlag)
  #
  #### Parameter Setting - catboost
  if (is.null(params)) {
    params =   list(iterations = 10,
                    depth = 6,
                    learning_rate = 0.02,
                    l2_leaf_reg = 0.9,
                    bagging_temperature = 0.9,
                    # random_strength = 1,
                    nan_mode = 'Min',
                    od_type = 'Iter')
  }


  cat_dt <- catboost::catboost.load_pool(data = x, label = y2)

  #### Validation
  if (valid == TRUE) {
    if (verbose) {
      message("Start Validation")
    }

        n <- length(y2)
    split_n <- round(0.8 * n)
    #----  Setup Test Set
    test_x <- x[1:split_n, ] %>% as.matrix
    test_y2 <- y2[1:split_n] %>% as.matrix
    cat_test <- catboost::catboost.load_pool(data = test_x, label = test_y2)

    #----  Setup Valid. Set
    valid_x <- x[(split_n + 1):n,] %>% as.matrix
    valid_y2 <- y2[(split_n + 1):n] %>% as.matrix
    cat_valid <- catboost::catboost.load_pool(data = valid_x, label = valid_y2)

    #---- Train with Catboost(validation)
    model <- catboost::catboost.train(cat_test, cat_valid, params = params)
  } else {
    #---- Train with Catboost (non-validation)
    model <- catboost::catboost.train(cat_dt, params = params)
  }


  #### PREDICTION


  if (!is.null(pred_xreg)) {
    xreg3 <- as.matrix(pred_xreg)
  } else {
    # xreg3 <- matrix(data = 0, nrow = h, ncol = 1)
    xreg3 <- NULL
  }


  rollup_cat <- function(x = x, y = y, model, xregpred, i,
                         f = 7) {

    newrow <- c(y[length(y)], x[nrow(x),c(1:maxlag-1) ])

    if (f > 1 & season_type == "dummy") {
      newrow <- c(newrow,
                  x[(nrow(x) + 1 - f), c((maxlag + 1):(maxlag + f - 1))],0)
    }
    if (!is.null(xregpred)) {
      newrow <- c(newrow, xregpred)
    }

    # if (is.null(xregpred)) {
    #   newrow <- cbind(newrow,0)
    # }

    newrow <- matrix(newrow, nrow = 1)
    # colnames(newrow) <- colnames(x)
    pred_pool <- catboost.load_pool(newrow)
    pred <- catboost.predict(model, pred_pool)
    return(list(x = rbind(x, newrow), y = c(y, pred)))
  }

x <- x_temp
y <- y2_temp
#
#### predict - rollup ts

if (!is.null(pred_xreg) ) {
  h = nrow(pred_xreg)
  } else {
    h = h
  }



for (i in 1:h) {
  tmp <-  rollup_cat(x, y,
                     model = model,
                     xregpred = xreg3[i, ],
                     i = i,
                     f= f )
  x <- tmp$x
  y <- tmp$y
}

pred_y <- ts(y[-(1:length(y2))],
             frequency = f,
             start = max(time(y)) + 1/f)

if (season_type == "decompose") {
  season_value <- utils::tail(decomp$seasonal, f)
  if (h < f) {
    season_value <- season_value[1:h]
  } else {
    pred_y <- pred_y * as.vector(season_value)
  }
}

result_y <- InvBoxcox(pred_y, lambda = lambda)

# if (log == TRUE) {
#   result_y <- expm1(result_y)
# }


output <- round(result_y)
return(output)
}

