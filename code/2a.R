rm(list = ls())
library(tidyverse)

# Data loading
EQ <- read.csv("EQ Dataset.csv")
required_columns <- c("YEAR", "MONTH", "dp", "rf", "re")

stopifnot(
  all(required_columns %in% names(EQ)),
  nrow(EQ) == 1129L
)

dp <- EQ$dp
rf <- EQ$rf
re <- EQ$re
month_index <- 12L * EQ$YEAR + EQ$MONTH

stopifnot(
  all(is.finite(c(dp, rf, re))),
  all(diff(month_index) == 1L)
)

H_max <- 15L
step_yr <- 12L
n <- nrow(EQ)

alpha <- numeric(H_max)
beta <- numeric(H_max)
adjusted_r_squared <- numeric(H_max)

for (H in seq_len(H_max)) {
  # Retain starting months with H full years of future observations
  t_index <- seq_len(n - step_yr * H)
  dividend_price_ratio <- exp(dp[t_index])
  average_excess_return <- numeric(length(t_index))

  for (h in seq_len(H)) {
    future_index <- t_index + step_yr * h
    xR_e_t_plus_h <- exp(re[future_index]) - exp(rf[future_index])
    average_excess_return <- average_excess_return + xR_e_t_plus_h
  }

  average_excess_return <- average_excess_return / H

  stopifnot(
    all(is.finite(average_excess_return)),
    var(dividend_price_ratio) > 0
  )

  horizon_model <- lm(average_excess_return ~ dividend_price_ratio)
  horizon_summary <- summary(horizon_model)

  alpha[H] <- unname(coef(horizon_model)[["(Intercept)"]])
  beta[H] <- unname(coef(horizon_model)[["dividend_price_ratio"]])
  adjusted_r_squared[H] <- horizon_summary$adj.r.squared

  stopifnot(nobs(horizon_model) == length(t_index))
}

regression_results <- tibble(
  H = seq_len(H_max),
  alpha = alpha,
  beta = beta,
  adjusted_r_squared = adjusted_r_squared
)

stopifnot(
  nrow(regression_results) == H_max,
  all(is.finite(unlist(regression_results)))
)

write_csv(regression_results, "code/2a.csv")

adjusted_r_squared_plot <- ggplot(
  regression_results,
  aes(x = H, y = adjusted_r_squared)
) +
  geom_hline(yintercept = 0, linetype = "dashed") +
  geom_line(color = "red", linewidth = 0.9) +
  geom_point(color = "red", size = 1.8) +
  scale_x_continuous(breaks = seq_len(H_max)) +
  labs(
    x = "Horizon H (years)",
    y = "Adjusted R-squared",
    title = "Figure 3: Adjusted R-squared of average excess return on dp by horizon"
  ) +
  theme_classic() +
  theme(
    text = element_text(
      family = "Times New Roman",
      size = 14
    ),
    plot.title = element_text(hjust = 0.5)
  )

dir.create("figures", showWarnings = FALSE, recursive = TRUE)
ggsave(
  filename = "figures/2a.png",
  plot = adjusted_r_squared_plot,
  width = 8,
  height = 5,
  dpi = 300,
  bg = "white"
)

print(regression_results, n = H_max)
