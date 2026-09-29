rm(list = ls())
library(tidyverse)

# Data loading and validation
EQ <- read.csv("data/EQ Dataset.csv")
required_columns <- c("YEAR", "MONTH", "dp", "rf", "re")

stopifnot(
  all(required_columns %in% names(EQ)),
  nrow(EQ) == 1129L
)

month_index <- 12L * EQ$YEAR + EQ$MONTH
dates <- as.Date(sprintf("%04d-%02d-01", EQ$YEAR, EQ$MONTH))
dividend_price_ratio <- exp(EQ$dp)
excess_return <- exp(EQ$re) - exp(EQ$rf)

stopifnot(
  all(is.finite(unlist(EQ[, required_columns]))),
  all(diff(month_index) == 1L),
  all(is.finite(c(dividend_price_ratio, excess_return)))
)

step_yr <- 12L
n <- nrow(EQ)

# Full-sample in-sample regression
full_start_index <- seq_len(n - step_yr)
full_target_index <- full_start_index + step_yr

full_sample <- tibble(
  xR_e_t_plus_1 = excess_return[full_target_index],
  D_P_t = dividend_price_ratio[full_start_index]
)

in_sample_model <- lm(xR_e_t_plus_1 ~ D_P_t, data = full_sample)
a_IS <- unname(coef(in_sample_model)[["(Intercept)"]])
b_IS <- unname(coef(in_sample_model)[["D_P_t"]])

stopifnot(
  nobs(in_sample_model) == 1117L,
  qr(model.matrix(in_sample_model))$rank == 2L
)

# Out-of-sample targets run from December 1940 through December 2021.
first_origin_index <- which(EQ$YEAR == 1939L & EQ$MONTH == 12L)
last_origin_index <- n - step_yr
origin_index <- seq.int(first_origin_index, last_origin_index)
target_index <- origin_index + step_yr
n_forecasts <- length(origin_index)

stopifnot(
  length(first_origin_index) == 1L,
  n_forecasts == 973L,
  dates[origin_index[1]] == as.Date("1939-12-01"),
  dates[target_index[1]] == as.Date("1940-12-01"),
  dates[target_index[n_forecasts]] == as.Date("2021-12-01"),
  all(target_index - origin_index == step_yr),
  dates[1L] == as.Date("1927-12-01"),
  dates[first_origin_index - step_yr - 1L] == as.Date("1938-11-01"),
  dates[1L + step_yr] == as.Date("1928-12-01"),
  dates[first_origin_index - 1L] == as.Date("1939-11-01")
)

a_OS <- numeric(n_forecasts)
b_OS <- numeric(n_forecasts)
historical_mean <- numeric(n_forecasts)
historical_mean_observations <- integer(n_forecasts)
in_sample_forecast <- numeric(n_forecasts)
out_of_sample_forecast <- numeric(n_forecasts)
realized_excess_return <- excess_return[target_index]
training_observations <- integer(n_forecasts)

for (forecast_number in seq_len(n_forecasts)) {
  current_origin <- origin_index[forecast_number]

  # Follow the prompt's literal calendar ranges. The first expanding sample uses
  # D/P from December 1927-November 1938 and returns from December 1928-November
  # 1939, so every target return predates the December 1939 forecast origin.
  training_start_index <- seq_len(current_origin - step_yr - 1L)
  training_target_index <- training_start_index + step_yr

  training_sample <- tibble(
    xR_e_s_plus_1 = excess_return[training_target_index],
    D_P_s = dividend_price_ratio[training_start_index]
  )

  expanding_model <- lm(xR_e_s_plus_1 ~ D_P_s, data = training_sample)

  a_OS[forecast_number] <- unname(coef(expanding_model)[["(Intercept)"]])
  b_OS[forecast_number] <- unname(coef(expanding_model)[["D_P_s"]])
  training_observations[forecast_number] <- nobs(expanding_model)
  # The historical benchmark begins in December 1928 and includes all monthly
  # excess returns through the forecast origin.
  historical_return_index <- seq.int(step_yr + 1L, current_origin)
  historical_mean[forecast_number] <- mean(
    excess_return[historical_return_index]
  )
  historical_mean_observations[forecast_number] <-
    length(historical_return_index)

  current_D_P <- dividend_price_ratio[current_origin]
  out_of_sample_forecast[forecast_number] <-
    a_OS[forecast_number] + b_OS[forecast_number] * current_D_P
  in_sample_forecast[forecast_number] <- a_IS + b_IS * current_D_P
}

forecast_results <- tibble(
  forecast_origin_date = dates[origin_index],
  target_date = dates[target_index],
  xR_e_t_plus_1 = realized_excess_return,
  historical_mean = historical_mean,
  in_sample_forecast = in_sample_forecast,
  out_of_sample_forecast = out_of_sample_forecast,
  a_OS = a_OS,
  b_OS = b_OS,
  N_t = historical_mean_observations,
  training_observations = training_observations
)

stopifnot(
  nrow(forecast_results) == 973L,
  all(is.finite(unlist(forecast_results[, 3:10]))),
  identical(training_observations, 132:1104),
  identical(historical_mean_observations, 133:1105),
  abs(historical_mean[1] -
    mean(excess_return[(step_yr + 1L):first_origin_index])) < 1e-14,
  abs(a_IS - (-0.031410878888682)) < 1e-12,
  abs(b_IS - 2.803802742996315) < 1e-12,
  is.finite(a_OS[1]),
  is.finite(b_OS[1])
)

dir.create("code", showWarnings = FALSE, recursive = TRUE)
write_csv(forecast_results, "code/2d_1.csv")

# Full-period out-of-sample R-squared
os_squared_errors <-
  (forecast_results$xR_e_t_plus_1 - forecast_results$out_of_sample_forecast)^2
historical_mean_squared_errors <-
  (forecast_results$xR_e_t_plus_1 - forecast_results$historical_mean)^2

SSE_OS <- sum(os_squared_errors)
SSE_historical_mean <- sum(historical_mean_squared_errors)
stopifnot(SSE_historical_mean > 0)

R_OS_squared <- 1 - SSE_OS / SSE_historical_mean

# Rolling R_OS^2. The prompt explicitly makes both endpoints inclusive, so
# January 1941 through December 1990 contains 50 * 12 observations.
rolling_window_observations <- 50L * 12L
first_rolling_start_position <- which(
  forecast_results$target_date == as.Date("1941-01-01")
)
first_rolling_end_position <- which(
  forecast_results$target_date == as.Date("1990-12-01")
)

stopifnot(
  length(first_rolling_start_position) == 1L,
  length(first_rolling_end_position) == 1L,
  first_rolling_end_position - first_rolling_start_position + 1L ==
    rolling_window_observations
)
rolling_end_position <- seq.int(
  from = first_rolling_end_position,
  to = n_forecasts
)
rolling_start_position <- rolling_end_position - rolling_window_observations + 1L

stopifnot(
  rolling_start_position[1] == first_rolling_start_position,
  all(diff(rolling_start_position) == 1L),
  all(diff(rolling_end_position) == 1L)
)

rolling_R_OS_squared <- vapply(
  seq_along(rolling_end_position),
  function(window_number) {
    window_index <- seq.int(
      rolling_start_position[window_number],
      rolling_end_position[window_number]
    )

    window_SSE_OS <- sum(os_squared_errors[window_index])
    window_SSE_historical_mean <- sum(
      historical_mean_squared_errors[window_index]
    )

    stopifnot(window_SSE_historical_mean > 0)
    1 - window_SSE_OS / window_SSE_historical_mean
  },
  numeric(1)
)

rolling_results <- tibble(
  window_start_date = forecast_results$target_date[rolling_start_position],
  window_end_date = forecast_results$target_date[rolling_end_position],
  window_observations = rolling_window_observations,
  rolling_R_OS_squared = rolling_R_OS_squared
)

stopifnot(
  nrow(rolling_results) == 373L,
  all(is.finite(rolling_results$rolling_R_OS_squared)),
  rolling_results$window_start_date[1] == as.Date("1941-01-01"),
  rolling_results$window_end_date[1] == as.Date("1990-12-01"),
  rolling_results$window_end_date[nrow(rolling_results)] ==
    as.Date("2021-12-01"),
  all(rolling_results$window_observations == 600L),
  is.finite(R_OS_squared)
)

write_csv(rolling_results, "code/2d_2.csv")

# Plot the historical benchmark and the two requested forecast series.
forecast_plot_data <- forecast_results |>
  select(
    target_date,
    historical_mean,
    in_sample_forecast,
    out_of_sample_forecast
  ) |>
  pivot_longer(
    cols = c(historical_mean, in_sample_forecast, out_of_sample_forecast),
    names_to = "series",
    values_to = "forecast"
  ) |>
  mutate(
    series = factor(
      series,
      levels = c(
        "historical_mean",
        "in_sample_forecast",
        "out_of_sample_forecast"
      )
    )
  )


forecast_date_breaks <- seq.Date(
  as.Date("1940-12-01"),
  as.Date("2020-12-01"),
  by = "5 years"
)

forecast_plot <- ggplot(
  forecast_plot_data,
  aes(x = target_date, y = forecast, color = series)
) +
  geom_hline(yintercept = 0, linetype = "dashed") +
  geom_line(linewidth = 0.7) +
  scale_color_manual(
    values = c(
      "historical_mean" = "green",
      "in_sample_forecast" = "blue",
      "out_of_sample_forecast" = "red"
    ),
     breaks = c(
      "historical_mean",
      "in_sample_forecast",
      "out_of_sample_forecast"
    ),
    labels = expression(
      bar(xR)[e,t],
      {hat(E)[t]^{IS}} ~ (xR[e,t+1]), 
      {hat(E)[t]^{OS}} ~ (xR[e,t+1])
    )
  ) +
  scale_x_date(breaks = forecast_date_breaks, date_labels = "%Y") +
  scale_y_continuous(breaks = seq(-0.05, 0.3, by = 0.05)) +
  labs(
    x = "",
    y = "",
    color = NULL,
    title = "Figure 4: Time series of sample mean, IS and OS estimates for xR"
  ) +
  theme_classic() +
  theme(
    text = element_text(family = "Times New Roman", size = 14),
    legend.position = "bottom",
    plot.title = element_text(hjust = 0.5)
  )

rolling_date_breaks <- seq.Date(
  as.Date("1990-12-01"),
  as.Date("2020-12-01"),
  by = "5 years"
)

rolling_plot <- ggplot(
  rolling_results,
  aes(x = window_end_date, y = rolling_R_OS_squared)
) +
  geom_hline(yintercept = 0, linetype = "dashed") +
  geom_line(color = "red", linewidth = 0.9) +
  scale_x_date(breaks = rolling_date_breaks, date_labels = "%Y") +
  scale_y_continuous(breaks = seq(-0.10, 0.20, by = 0.05)) +
  labs(
    x = "Years",
    y = expression(R[OS]^2),
    title = "Figure 5: Rolling 50-year out-of-sample R-squared"
  ) +
  theme_classic() +
  theme(
    text = element_text(family = "Times New Roman", size = 14
    ),
    plot.title = element_text(hjust = 0.5
    ),
    panel.grid.major = element_line(color = "gray85", linewidth=0.5
    ),
    panel.grid.minor = element_blank())

dir.create("figures", showWarnings = FALSE, recursive = TRUE)
ggsave(
  filename = "figures/2d_1.png",
  plot = forecast_plot,
  width = 8,
  height = 5,
  dpi = 300,
  bg = "white"
)
ggsave(
  filename = "figures/2d_2.png",
  plot = rolling_plot,
  width = 8,
  height = 5,
  dpi = 300,
  bg = "white"
)

summary_results <- tibble(
  in_sample_observations = nobs(in_sample_model),
  out_of_sample_forecasts = n_forecasts,
  first_forecast_target_date = forecast_results$target_date[1],
  last_forecast_target_date = forecast_results$target_date[n_forecasts],
  first_training_observations = training_observations[1],
  last_training_observations = training_observations[n_forecasts],
  first_historical_mean_observations = historical_mean_observations[1],
  last_historical_mean_observations =
    historical_mean_observations[n_forecasts],
  a_IS = a_IS,
  b_IS = b_IS,
  SSE_OS = SSE_OS,
  SSE_historical_mean = SSE_historical_mean,
  R_OS_squared = R_OS_squared,
  rolling_window_observations = rolling_window_observations,
  rolling_estimates = nrow(rolling_results),
  first_rolling_window_start_date = rolling_results$window_start_date[1],
  first_rolling_window_end_date = rolling_results$window_end_date[1],
  last_rolling_window_start_date =
    rolling_results$window_start_date[nrow(rolling_results)],
  last_rolling_window_end_date =
    rolling_results$window_end_date[nrow(rolling_results)],
  first_rolling_R_OS_squared = rolling_R_OS_squared[1],
  last_rolling_R_OS_squared =
    rolling_R_OS_squared[length(rolling_R_OS_squared)],
  minimum_rolling_R_OS_squared = min(rolling_R_OS_squared),
  maximum_rolling_R_OS_squared = max(rolling_R_OS_squared)
)

write_csv(summary_results, "code/2d_summary.csv")

print(summary_results, width = Inf)
print(head(forecast_results))
print(head(rolling_results))
