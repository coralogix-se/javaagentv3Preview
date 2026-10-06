package com.example.orders;

import java.util.Map;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

@RestController
@RequestMapping("/orders")
public class OrderController {
  private static final Logger log = LoggerFactory.getLogger(OrderController.class);

  private final OrderRepository orders;

  public OrderController(OrderRepository orders) {
    this.orders = orders;
  }

  @GetMapping
  public Map<String, Object> list() {
    var rows = orders.list();
    log.atInfo().addKeyValue("order.count", rows.size()).log("listed orders");
    return Map.of("orders", rows);
  }

  @GetMapping("/{id}")
  public Order get(@PathVariable long id) {
    return orders
        .find(id)
        .orElseThrow(() -> new ResponseStatusException(HttpStatus.NOT_FOUND, "order not found"));
  }

  @PostMapping
  @ResponseStatus(HttpStatus.CREATED)
  public Order create(@RequestBody CreateOrder request) {
    String sku = request.sku() == null || request.sku().isBlank() ? "widget" : request.sku();
    int qty = request.qty() <= 0 ? 1 : request.qty();
    Order created = orders.insert(sku, qty);
    log.atInfo()
        .addKeyValue("order.id", created.id())
        .addKeyValue("order.sku", created.sku())
        .log("created order");
    return created;
  }

  @PutMapping("/{id}")
  public Map<String, Object> update(@PathVariable long id, @RequestBody CreateOrder request) {
    int qty = request.qty() <= 0 ? 1 : request.qty();
    int updated = orders.updateQty(id, qty);
    if (updated == 0) {
      throw new ResponseStatusException(HttpStatus.NOT_FOUND, "order not found");
    }
    log.atInfo().addKeyValue("order.id", id).addKeyValue("order.qty", qty).log("updated order");
    return Map.of("id", id, "qty", qty);
  }

  @GetMapping("/boom")
  public void boom() {
    orders.queryMissingTable();
  }

  @Scheduled(fixedDelay = 15000, initialDelay = 10000)
  public void heartbeat() {
    int count = orders.count();
    log.atInfo().addKeyValue("order.count", count).log("orders heartbeat");
  }

  public record CreateOrder(String sku, int qty) {}
}
