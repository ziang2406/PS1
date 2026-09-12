rm(list = ls())
library(tidyverse)
library(sandwich)

# Data loading and one-year-ahead predictive-regression sample
EQ <- read.csv("EQ Dataset.csv")
required_columns <- c("YEAR", "MONTH", "dp", "rf", "re")

stopifnot(
  all(required_columns %in% names(EQ)),
  nrow(EQ) == 1129L
)

month_index <- 12L * EQ$YEAR + EQ$MONTH
stopifnot(
  all(is.finite(unlist(EQ[, required_columns]))),
  all(diff(month_index) == 1L)
)

step_yr <- 12L
n <- nrow(EQ)
t_index <- seq_len(n - step_yr)
future_index <- t_index + step_yr

regression_data <- tibble(
  excess_return = exp(EQ$re[future_index]) - exp(EQ$rf[future_index]),
  dividend_price_ratio = exp(EQ$dp[t_index])
)

stopifnot(
  nrow(regression_data) == 1117L,
  all(is.finite(unlist(regression_data))),
  var(regression_data$dividend_price_ratio) > 0
)

predictive_model <- lm(excess_return ~ dividend_price_ratio, data = regression_data)
X <- model.matrix(predictive_model)
residual <- residuals(predictive_model)
T_reg <- nrow(X)
k <- ncol(X)

stopifnot(
  nobs(predictive_model) == 1117L,
  k == 2L,
  qr(X)$rank == k
)

# Compute the HAC covariance matrix using the assignment's normalization:
# Omega_l divides by T - l, rather than by T at every lag.
hac_covariance <- function(model, lag, kernel = c("Bartlett", "Truncated")) {
  kernel <- match.arg(kernel)
  X_model <- model.matrix(model)
  score <- X_model * residuals(model)
  T_model <- nrow(X_model)

  stopifnot(
    length(lag) == 1L,
    is.finite(lag),
    lag == as.integer(lag),
    lag >= 0L,
    lag < T_model
  )
  lag <- as.integer(lag)

  S_hat <- crossprod(score) / T_model

  if (lag > 0L) {
    for (ell in seq_len(lag)) {
      current_score <- score[(ell + 1L):T_model, , drop = FALSE]
      lagged_score <- score[seq_len(T_model - ell), , drop = FALSE]
      omega_ell <- crossprod(current_score, lagged_score) / (T_model - ell)

      weight <- if (kernel == "Bartlett") {
        1 - ell / (lag + 1L)
      } else {
        1
      }

      S_hat <- S_hat + weight * (omega_ell + t(omega_ell))
    }
  }

  Q_inv <- solve(crossprod(X_model) / T_model)
  covariance <- Q_inv %*% S_hat %*% Q_inv / T_model
  covariance <- (covariance + t(covariance)) / 2
  dimnames(covariance) <- list(colnames(X_model), colnames(X_model))
  covariance
}

# 1. Conventional homoskedastic OLS covariance, with sigma^2 = RSS / (T - k)
sigma_squared_ols <- sum(residual^2) / (T_reg - k)
ols_covariance <- sigma_squared_ols * solve(crossprod(X))

# 2. White (1980) HC0 covariance, without a finite-sample correction
score <- X * residual
white_covariance <- solve(crossprod(X)) %*%
  crossprod(score) %*%
  solve(crossprod(X))
dimnames(white_covariance) <- list(colnames(X), colnames(X))

# 3. Newey-West (1987), Bartlett weights through lag 11
nw_fixed_lag <- 11L
nw_fixed_covariance <- hac_covariance(
  predictive_model,
  lag = nw_fixed_lag,
  kernel = "Bartlett"
)

# 4. Hansen-Hodrick (1980), equal weights through lag 11
hh_lag <- 11L
hh_covariance <- hac_covariance(
  predictive_model,
  lag = hh_lag,
  kernel = "Truncated"
)

# 5. Automatic Newey-West (1987, 1994), without prewhitening
automatic_bandwidth <- sandwich::bwNeweyWest(
  predictive_model,
  kernel = "Bartlett",
  prewhite = FALSE
)
automatic_lag <- floor(automatic_bandwidth)
nw_automatic_covariance <- hac_covariance(
  predictive_model,
  lag = automatic_lag,
  kernel = "Bartlett"
)

# Confirm the conventional OLS and HC0 implementations against standard R methods.
stopifnot(
  isTRUE(all.equal(ols_covariance, vcov(predictive_model), tolerance = 1e-12)),
  isTRUE(all.equal(
    white_covariance,
    sandwich::vcovHC(predictive_model, type = "HC0"),
    tolerance = 1e-12
  )),
  automatic_lag == 22L
)

covariance_matrices <- list(
  ols_covariance,
  white_covariance,
  nw_fixed_covariance,
  hh_covariance,
  nw_automatic_covariance
)

method_names <- c(
  "OLS",
  "White (1980)",
  "Newey-West (1987), 11 lags",
  "Hansen-Hodrick (1980), 11 lags",
  sprintf("Newey-West (1987, 1994), automatic (%d lags)", automatic_lag)
)

slope_name <- "dividend_price_ratio"
b_hat <- unname(coef(predictive_model)[[slope_name]])
standard_errors <- vapply(
  covariance_matrices,
  function(covariance) sqrt(covariance[slope_name, slope_name]),
  numeric(1)
)
t_statistics <- b_hat / standard_errors

stopifnot(
  all(is.finite(c(b_hat, standard_errors, t_statistics))),
  all(standard_errors > 0),
  all(abs(t_statistics - b_hat / standard_errors) < 1e-12)
)

results <- tibble(
  method = method_names,
  b_hat = b_hat,
  std_error = standard_errors,
  t_stat = t_statistics
) |>
  mutate(across(c(b_hat, std_error, t_stat), ~ round(.x, 4)))

dir.create("code", showWarnings = FALSE, recursive = TRUE)
csv_results <- results |>
  mutate(across(c(b_hat, std_error, t_stat), ~ sprintf("%.4f", .x)))
write_csv(csv_results, "code/2b.csv")

latex_rows <- sprintf(
  "    %s & %.4f & %.4f & %.4f \\\\",
  c(
    "OLS",
    "White (1980)",
    "Newey--West (1987), 11 lags",
    "Hansen--Hodrick (1980), 11 lags",
    sprintf("Newey--West (1987, 1994), automatic (%d lags)", automatic_lag)
  ),
  results$b_hat,
  results$std_error,
  results$t_stat
)

latex_table <- c(
  "\\begin{table}[htbp]",
  "  \\centering",
  "  \\caption{Predictive-regression coefficient estimates and standard errors}",
  "  \\label{tab:q2b}",
  "  \\begin{tabular}{lrrr}",
  "    \\toprule",
  "    Method & $\\hat{b}$ & Std. Error & $t$-stat \\\\",
  "    \\midrule",
  latex_rows,
  "    \\bottomrule",
  "  \\end{tabular}",
  "\\end{table}"
)

dir.create("figures", showWarnings = FALSE, recursive = TRUE)
writeLines(latex_table, "figures/2b.tex")

cat(sprintf(
  "Automatic Newey-West bandwidth: %.6f; selected lag: %d\n\n",
  automatic_bandwidth,
  automatic_lag
))
cat(paste(latex_table, collapse = "\n"), "\n\n")
print(results, n = nrow(results))
