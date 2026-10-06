package com.example.orders;

import java.util.List;
import java.util.Optional;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.support.GeneratedKeyHolder;
import org.springframework.jdbc.support.KeyHolder;
import org.springframework.stereotype.Repository;

@Repository
public class OrderRepository {
  private final JdbcTemplate jdbc;

  public OrderRepository(JdbcTemplate jdbc) {
    this.jdbc = jdbc;
  }

  public Order insert(String sku, int qty) {
    KeyHolder keys = new GeneratedKeyHolder();
    jdbc.update(
        connection -> {
          var ps =
              connection.prepareStatement(
                  "INSERT INTO shop.orders (sku, qty) VALUES (?, ?)", new String[] {"id"});
          ps.setString(1, sku);
          ps.setInt(2, qty);
          return ps;
        },
        keys);
    Number id = keys.getKey();
    if (id == null) {
      throw new IllegalStateException("insert did not return an id");
    }
    return find(id.longValue()).orElseThrow();
  }

  public List<Order> list() {
    return jdbc.query(
        "SELECT id, sku, qty, created_at FROM shop.orders ORDER BY id DESC LIMIT 20",
        (rs, row) ->
            new Order(
                rs.getLong("id"),
                rs.getString("sku"),
                rs.getInt("qty"),
                rs.getTimestamp("created_at").toInstant().toString()));
  }

  public Optional<Order> find(long id) {
    var rows =
        jdbc.query(
            "SELECT id, sku, qty, created_at FROM shop.orders WHERE id = ?",
            (rs, row) ->
                new Order(
                    rs.getLong("id"),
                    rs.getString("sku"),
                    rs.getInt("qty"),
                    rs.getTimestamp("created_at").toInstant().toString()),
            id);
    return rows.stream().findFirst();
  }

  public int updateQty(long id, int qty) {
    return jdbc.update("UPDATE shop.orders SET qty = ? WHERE id = ?", qty, id);
  }

  public int count() {
    Integer count =
        jdbc.queryForObject("SELECT count(*) FROM shop.orders", Integer.class);
    return count == null ? 0 : count;
  }

  public void queryMissingTable() {
    jdbc.queryForObject("SELECT id FROM shop.missing_table", Long.class);
  }
}
