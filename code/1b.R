rm(list=ls())
library(tidyverse)

#data loading 
EQ <- read.csv("EQ Dataset.csv")
dp <- EQ$dp
dg <- EQ$dg
re <- EQ$re
H_max <- 20 #setting max horizons in years
step_yr <- 12 
n <- nrow(EQ)
var_dp <- var(dp, na.rm = TRUE)

#using our derivation in Q1 part a, we define kappa as follows:
kappa <- 1/(1+ exp(mean(dp)))

#creating the main function for the loop 
b_re <- numeric(H_max)
b_dg <- numeric(H_max)
b_dp <- numeric(H_max)

for (H in seq_len(H_max)) {
  # Starting months that have H years of future monthly data available
  t_index <- seq_len(n - step_yr * H)
  dp_t <- dp[t_index]

  sum_re <- numeric(length(t_index))
  sum_dg <- numeric(length(t_index))

  for (h in seq_len(H)) {
    future_index <- t_index + step_yr * h
    discount_weight <- kappa^(h - 1)

    sum_re <- sum_re + discount_weight * re[future_index]
    sum_dg <- sum_dg + discount_weight * dg[future_index]
  }

  sum_dp <- kappa^H * dp[t_index + step_yr * H]

  b_re[H] <- unname(coef(lm(sum_re ~ dp_t))["dp_t"])
  b_dg[H] <- unname(coef(lm(-sum_dg ~ dp_t))["dp_t"])
  b_dp[H] <- unname(coef(lm(sum_dp ~ dp_t))["dp_t"])
}

# Store the estimated slopes by horizon
slope_results <- tibble(
  H = seq_len(H_max),
  b_re = b_re,
  b_dg = b_dg,
  b_dp = b_dp
)

# Convert the results to long form for plotting
slope_plot_data <- slope_results |>
  pivot_longer(
    cols = c(b_re, b_dg, b_dp),
    names_to = "coefficient",
    values_to = "slope"
  )

slope_plot <- ggplot(
  slope_plot_data,
  aes(x = H, y = slope, color = coefficient)
) +
  geom_hline(yintercept = 0, linetype = "dashed") +
  geom_line(linewidth = 0.9) +
  scale_color_manual(
    values = c(
        "b_re" = "red",
        "b_dg" = "blue",
        "b_dp" = "green"
    ),
    labels = c(
        "b_re" = expression(beta[re]^{(H)}),
        "b_dg" = expression(beta[dg]^{(H)}),
        "b_dp" = expression(beta[dp]^{(H)})
    ) 
 )+
  scale_x_continuous(breaks = seq_len(H_max)) +
  scale_y_continuous(breaks = seq(-0.3, 1.1, by = 0.2)) +
  labs(
    x = "Horizon H (years)",
    y = "OLS slope on dp_t",
    color = NULL,
    title = "Figure 1: Variance decomposition of dp_t"
  ) +
  theme_classic() +
    theme(
        text = element_text(
            family = "Times New Roman",
            size = 14),
        legend.position = c(0.20,0.80),
        legend.text = element_text(size = 12),
        plot.title = element_text(hjust = 0.5)
    )

dir.create("figures", showWarnings = FALSE, recursive = TRUE)
ggsave(
  filename = "figures/1b_figure.png",
  plot = slope_plot,
  width = 8,
  height = 5,
  dpi = 300,
  bg = "white"
)

print(slope_results)
