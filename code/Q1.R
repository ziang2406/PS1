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

