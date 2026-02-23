#pragma once
#include "insights/core/result.hpp"
#include "insights/core/traits.hpp"

#include <exception>
#include <expected>
#include <format>
#include <memory>
#include <pqxx/pqxx>
#include <pqxx/zview>
#include <spdlog/spdlog.h>
#include <string>
#include <utility>
#include <vector>

namespace insights::db {
struct Database {
  pqxx::connection Cx;

  explicit Database(const std::string &ConnString)
      : Cx(ConnString), ConnString(ConnString) {}

  static std::expected<std::shared_ptr<Database>, core::Error>
  connect(const std::string &ConnString) {
    try {
      spdlog::debug("Database::connect - Establishing connection");
      auto Db = std::make_shared<Database>(ConnString);
      spdlog::info("Database::connect - Successfully connected to database");
      return Db;
    } catch (const std::exception &Err) {
      spdlog::error("Database::connect - Connection failed: {}", Err.what());
      return std::unexpected(core::Error{Err.what()});
    }
  }

  bool reconnect() {
    spdlog::warn("Database::reconnect - Attempting to reconnect");
    try {
      Cx = pqxx::connection(ConnString);
      spdlog::info("Database::reconnect - Reconnected successfully");
      return true;
    } catch (const std::exception &Err) {
      spdlog::error("Database::reconnect - Failed: {}", Err.what());
      return false;
    }
  }

private:
  std::string ConnString;

public:

  template <core::DbEntity T>
  std::expected<T, core::Error> create(const T &Entity) {
    try {
      spdlog::trace(
          "Database::create<{}> - Starting transaction",
          core::DbTraits<T>::TableName
      );
      pqxx::work Tx(Cx);
      auto Params = core::DbTraits<T>::toParams(Entity);

      auto PlaceHolders = []<std::size_t... Is>(std::index_sequence<Is...>) {
        return (
            std::string{} + ... +
            (Is == 0 ? "$1" : ", $" + std::to_string(Is + 1))
        );
      }(std::make_index_sequence<std::tuple_size_v<decltype(Params)>>{});

      auto Query = std::format(
          "INSERT INTO {} ({}) VALUES ({}) RETURNING *",
          core::DbTraits<T>::TableName,
          core::DbTraits<T>::Columns,
          PlaceHolders
      );

      spdlog::trace(
          "Database::create<{}> - Query: {}",
          core::DbTraits<T>::TableName,
          Query
      );

      pqxx::result Res;
      std::apply(
          [&](auto &&...Args) {
            Res = Tx.exec(pqxx::zview{Query}, pqxx::params{Args...});
          },
          Params
      );

      Tx.commit();
      spdlog::trace(
          "Database::create<{}> - Successfully created entity",
          core::DbTraits<T>::TableName
      );

      return core::DbTraits<T>::fromRow(Res[0]);
    } catch (const std::exception &Err) {
      spdlog::error(
          "Database::create<{}> - Failed: {}",
          core::DbTraits<T>::TableName,
          Err.what()
      );
      return std::unexpected(core::Error{Err.what()});
    }
  }

  template <core::DbEntity T>
  std::expected<T, core::Error> get(std::string_view Id) {
    try {
      spdlog::trace(
          "Database::get<{}> - Fetching entity with ID: {}",
          core::DbTraits<T>::TableName,
          Id
      );
      pqxx::work Tx(Cx);

      auto Query = std::format(
          "SELECT * FROM {} WHERE id = $1", core::DbTraits<T>::TableName
      );

      auto Result = Tx.exec(pqxx::zview{Query}, pqxx::params{Id});

      if (Result.empty()) {
        spdlog::debug(
            "Database::get<{}> - Entity not found: {}",
            core::DbTraits<T>::TableName,
            Id
        );
        return std::unexpected(core::Error{"Not found"});
      }

      spdlog::trace(
          "Database::get<{}> - Successfully retrieved entity",
          core::DbTraits<T>::TableName
      );
      return core::DbTraits<T>::fromRow(Result[0]);
    } catch (const std::exception &Err) {
      spdlog::error(
          "Database::get<{}> - Failed: {}",
          core::DbTraits<T>::TableName,
          Err.what()
      );
      return std::unexpected(core::Error{Err.what()});
    }
  }

  template <core::DbEntity T>
  std::expected<T, core::Error> remove(std::string_view Id) {
    try {
      spdlog::trace(
          "Database::remove<{}> - Soft deleting entity with ID: {}",
          core::DbTraits<T>::TableName,
          Id
      );
      pqxx::work Tx(Cx);

      auto Query = std::format(
          "UPDATE {} SET deleted_at = NOW() WHERE id = $1 RETURNING *",
          core::DbTraits<T>::TableName
      );

      auto Res = Tx.exec(pqxx::zview(Query), pqxx::params{Id});

      Tx.commit();
      spdlog::trace(
          "Database::remove<{}> - Successfully soft deleted entity",
          core::DbTraits<T>::TableName
      );
      return core::DbTraits<T>::fromRow(Res[0]);
    } catch (const std::exception &Err) {
      spdlog::error(
          "Database::remove<{}> - Failed: {}",
          core::DbTraits<T>::TableName,
          Err.what()
      );
      return std::unexpected(core::Error{Err.what()});
    }
  }

  template <core::DbEntity T>
  std::expected<T, core::Error> update(const T &Entity) {
    try {
      spdlog::trace(
          "Database::update<{}> - Updating entity with ID: {}",
          core::DbTraits<T>::TableName,
          Entity.Id
      );
      pqxx::work Tx(Cx);
      auto Params = core::DbTraits<T>::toParams(Entity);

      auto Query = std::format(
          "UPDATE {} SET {}, updated_at = NOW() WHERE id = ${} RETURNING *",
          core::DbTraits<T>::TableName,
          core::DbTraits<T>::UpdateSet,
          std::tuple_size_v<decltype(Params)> + 1
      );

      pqxx::result Res;
      std::apply(
          [&](auto &&...Args) {
            Res = Tx.exec(pqxx::zview{Query}, pqxx::params{Args..., Entity.Id});
          },
          Params
      );

      Tx.commit();
      spdlog::trace(
          "Database::update<{}> - Successfully updated entity",
          core::DbTraits<T>::TableName
      );
      return core::DbTraits<T>::fromRow(Res[0]);
    } catch (const std::exception &Err) {
      spdlog::error(
          "Database::update<{}> - Failed: {}",
          core::DbTraits<T>::TableName,
          Err.what()
      );
      return std::unexpected(core::Error{Err.what()});
    }
  }

  template <core::DbEntity T>
  std::expected<std::vector<T>, core::Error> getAll() {
    try {
      spdlog::trace(
          "Database::getAll<{}> - Fetching all entities",
          core::DbTraits<T>::TableName
      );
      pqxx::work Tx(Cx);
      auto Query =
          std::format("SELECT * FROM {}", core::DbTraits<T>::TableName);

      auto Res = Tx.exec(pqxx::zview(Query));

      std::vector<T> Results;
      for (const auto &Row : Res) {
        Results.push_back(core::DbTraits<T>::fromRow(Row));
      }

      spdlog::trace(
          "Database::getAll<{}> - Successfully retrieved {} entities",
          core::DbTraits<T>::TableName,
          Results.size()
      );
      return Results;

    } catch (const std::exception &Err) {
      spdlog::error(
          "Database::getAll<{}> - Failed: {}",
          core::DbTraits<T>::TableName,
          Err.what()
      );
      return std::unexpected(core::Error{Err.what()});
    }
  }
};
} // namespace insights::db
