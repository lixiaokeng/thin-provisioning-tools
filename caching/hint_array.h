#ifndef CACHE_HINT_ARRAY_H
#define CACHE_HINT_ARRAY_H

#include "persistent-data/data-structures/array.h"

#include <string>

//----------------------------------------------------------------

namespace caching {
	namespace hint_array_damage {
		class damage_visitor;

		class damage {
		public:
			damage(std::string const &desc)
				: desc_(desc) {
			}

			virtual ~damage() {}
			virtual void visit(damage_visitor &v) const = 0;

			std::string get_desc() const {
				return desc_;
			}

		private:
			std::string desc_;
		};

		struct missing_hints : public damage {
			missing_hints(std::string const desc, run<uint32_t> const &keys);
			virtual void visit(damage_visitor &v) const;

			run<uint32_t> keys_;
		};

		class damage_visitor {
		public:
			virtual ~damage_visitor() {}

			virtual void visit(damage const &d) {
				d.visit(*this);
			}

			virtual void visit(missing_hints const &d) = 0;
		};
	}

	class hint_array {
	public:
		typedef boost::shared_ptr<hint_array> ptr;
		typedef typename persistent_data::transaction_manager::ptr tm_ptr;

		hint_array(tm_ptr tm, unsigned width);
		hint_array(tm_ptr tm, unsigned width, block_address root, unsigned nr_entries);

		unsigned get_nr_entries() const;


		void grow(unsigned new_nr_entries, void const *v);

		block_address get_root() const;
		void get_hint(unsigned index, vector<unsigned char> &data) const;
		void set_hint(unsigned index, vector<unsigned char> const &data);

		void grow(unsigned new_nr_entries, vector<unsigned char> const &value);
		void check(hint_array_damage::damage_visitor &visitor);

	private:
		unsigned width_;
		boost::shared_ptr<persistent_data::array_base> impl_;
	};
}

//----------------------------------------------------------------

#endif