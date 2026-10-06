package com.example.orders;

public record Order(long id, String sku, int qty, String createdAt) {}
