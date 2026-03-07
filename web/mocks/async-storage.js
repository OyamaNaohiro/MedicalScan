const storage = {};

export default {
  getItem: async (key) => storage[key] || null,
  setItem: async (key, value) => {
    storage[key] = value;
  },
  removeItem: async (key) => {
    delete storage[key];
  },
};
