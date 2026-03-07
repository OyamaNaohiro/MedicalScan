export default {
  open: async (options) => {
    console.log('[Web Mock] Share.open:', options);
    alert(`共有プレビュー:\n件名: ${options.subject}\nファイル: ${options.url}`);
  },
};
