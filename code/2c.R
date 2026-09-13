rm(list = ls())
library(tidyverse)

# Data loading and one-year-ahead regression sample
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
  dividend_price_ratio = exp(EQ$dp[t_index]),
  future_dividend_price_ratio = exp(EQ$dp[future_index])
)

stopifnot(
  nrow(regression_data) == 1117L,
  all(is.finite(unlist(regression_data))),
  var(regression_data$dividend_price_ratio) > 0
)

# Estimate D_{t+1}/P_{t+1} = theta + phi * D_t/P_t + u_{t+1}.
ar_model <- lm(
  future_dividend_price_ratio ~ dividend_price_ratio,
  data = regression_data
)

theta_hat <- unname(coef(ar_model)[["(Intercept)"]])
phi_hat <- unname(coef(ar_model)[["dividend_price_ratio"]])

# Convert the full monthly sample length to years as specified in prompt/2c.md.
T_years <- nrow(EQ) / 12
phi_corrected <- phi_hat +
  (1 / T_years) * (1 + 3 * phi_hat) +
  (3 / T_years^2) * (1 + 3 * phi_hat)

regression_data <- regression_data |>
  mutate(
    u_corrected = future_dividend_price_ratio -
      (theta_hat + phi_corrected * dividend_price_ratio)
  )

# Estimate xR_{e,t+1} = a + b * D_t/P_t + b_u * u^c_{t+1} + e_{t+1}.
ah_model <- lm(
  excess_return ~ dividend_price_ratio + u_corrected,
  data = regression_data
)

b_AH <- unname(coef(ah_model)[["dividend_price_ratio"]])
b_u_hat <- unname(coef(ah_model)[["u_corrected"]])

stopifnot(
  nobs(ar_model) == 1117L,
  nobs(ah_model) == 1117L,
  qr(model.matrix(ar_model))$rank == 2L,
  qr(model.matrix(ah_model))$rank == 3L,
  isTRUE(all.equal(T_years, 1129 / 12, tolerance = 1e-15)),
  all(is.finite(c(
    theta_hat,
    phi_hat,
    phi_corrected,
    b_u_hat,
    b_AH
  ))),
  isTRUE(all.equal(
    regression_data$u_corrected,
    regression_data$future_dividend_price_ratio -
      (theta_hat + phi_corrected * regression_data$dividend_price_ratio),
    tolerance = 1e-15
  ))
)

results <- tibble(b_AH = b_AH)

dir.create("code", showWarnings = FALSE, recursive = TRUE)
write_csv(results, "code/2c.csv")

diagnostics <- tibble(
  regression_observations = nobs(ah_model),
  T_years = T_years,
  theta_hat = theta_hat,
  phi_hat = phi_hat,
  phi_corrected = phi_corrected,
  b_u_hat = b_u_hat,
  b_AH = b_AH
)

print(diagnostics)
print(results)
